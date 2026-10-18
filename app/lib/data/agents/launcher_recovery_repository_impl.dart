import 'dart:async';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/domain/contracts/launcher_recovery_repository.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/pairing/storage.dart';

/// Pins a live paired child and each explicitly selected destination incarnation.
/// The origin is only a fresh host result; legacy choices never become provenance.
class LauncherRecoveryRepositoryImpl extends LauncherRecoveryRepository {
  LauncherRecoveryRepositoryImpl(this._conn, this._storage, this._controls);
  final ConnectionManager _conn;
  final PairingStorage _storage;
  final SessionControlRepository _controls;
  String? _peer, _child;
  IChannel? _channel;
  int? _epoch;
  final _rooms = <String, int>{};
  final _candidates = <String, int>{};
  bool _invalid = false, _moving = false;
  final _invalidations = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get invalidations => _invalidations.stream;
  StreamSubscription<Object?>? _status, _discovery;

  bool get _current =>
      !_invalid &&
      _peer != null &&
      identical(_channel, _conn.channel) &&
      _conn.activePeer?.remoteEpk == _peer &&
      (_moving || _epoch == _conn.roomSelectionEpoch) &&
      _rooms.entries.every(
        (entry) =>
            _conn.isRoomLive(_peer!, entry.key) &&
            _conn
                .roomsFor(_peer!)
                .any(
                  (r) => r.roomId == entry.key && r.startedAt == entry.value,
                ),
      );

  void _check() {
    if (!_current) {
      invalidate();
      throw const SessionControlFailure(
        'Session changed or offline. Reopen from Home.',
      );
    }
  }

  @override
  Future<LaunchingHost?> resolve(String peer, String child) async {
    if (_peer != null || _invalid) {
      throw const SessionControlFailure('Recovery closed. Reopen from Home.');
    }
    final beforeChannel = _conn.channel;
    final beforePeer = _conn.activePeer?.remoteEpk;
    final beforeEpoch = _conn.roomSelectionEpoch;
    final beforeRoom = _conn
        .roomsFor(peer)
        .where((r) => r.roomId == child)
        .firstOrNull;
    final peers = await _storage.listPeers();
    if (!identical(beforeChannel, _conn.channel) ||
        beforeEpoch != _conn.roomSelectionEpoch ||
        beforePeer != _conn.activePeer?.remoteEpk ||
        beforeRoom == null ||
        !_conn
            .roomsFor(peer)
            .any(
              (r) => r.roomId == child && r.startedAt == beforeRoom.startedAt,
            )) {
      invalidate();
      throw const SessionControlFailure('Session changed. Reopen from Home.');
    }
    if (_invalid ||
        !peers.any((p) => p.remoteEpk == peer) ||
        !_conn.isRoomLive(peer, child)) {
      throw const SessionControlFailure(
        'Paired session offline. Check status from Home.',
      );
    }
    final record = peers.firstWhere((p) => p.remoteEpk == peer);
    await _conn.switchTo(record.copyWith(roomId: child));
    if (_invalid ||
        _conn.activePeer?.remoteEpk != peer ||
        beforePeer == peer &&
            (beforeEpoch != _conn.roomSelectionEpoch ||
                !identical(beforeChannel, _conn.channel)) ||
        !_conn
            .roomsFor(peer)
            .any(
              (r) => r.roomId == child && r.startedAt == beforeRoom.startedAt,
            ) ||
        !_conn.isRoomLive(peer, child)) {
      throw const SessionControlFailure(
        'Session offline. Check status from Home.',
      );
    }
    _conn.switchRoom(child);
    _peer = peer;
    _child = child;
    _channel = _conn.channel;
    _epoch = _conn.roomSelectionEpoch;
    _remember(child);
    void changed(Object? _) {
      if (!_current) invalidate();
    }

    _status = _conn.statusStream.listen(changed);
    _discovery = _conn.roomsStream.listen(changed);
    _check();
    try {
      final status = await _controls.inspect(peer, child);
      _check();
      return status.launchingHost;
    } on SessionControlFailure {
      _check();
      // Old hosts may lack controls metadata; never manufacture an origin.
      return null;
    }
  }

  void _remember(String room) {
    if (!_conn.isRoomLive(_peer!, room)) {
      throw const SessionControlFailure(
        'Launching host offline. Check status from Home.',
      );
    }
    final matches = _conn.roomsFor(_peer!).where((r) => r.roomId == room);
    if (matches.length != 1) {
      throw const SessionControlFailure(
        'Session unavailable. Check status from Home.',
      );
    }
    _rooms[room] = matches.single.startedAt;
  }

  @override
  List<LaunchHostChoice> get choices {
    _check();
    _candidates.clear();
    for (final room in _conn.roomsFor(_peer!)) {
      if (_conn.isRoomLive(_peer!, room.roomId)) {
        _candidates[room.roomId] = room.startedAt;
      }
    }
    return _conn
        .roomsFor(_peer!)
        .where((r) => _conn.isRoomLive(_peer!, r.roomId))
        .map(
          (r) => LaunchHostChoice(r.roomId, r.localName ?? r.name ?? r.roomId),
        )
        .toList();
  }

  Future<void> _select(String room) async {
    _check();
    final peers = await _storage.listPeers();
    _check();
    if (!peers.any((p) => p.remoteEpk == _peer)) {
      invalidate();
      throw const SessionControlFailure('Pairing changed. Reopen from Home.');
    }
    _remember(room);
    _moving = true;
    try {
      _conn.switchRoom(room);
      _epoch = _conn.roomSelectionEpoch;
    } finally {
      _moving = false;
    }
    _check();
  }

  @override
  Future<void> selectParent(String room) async {
    _check();
    if (_candidates.isNotEmpty &&
        !_conn
            .roomsFor(_peer!)
            .any((r) => r.roomId == room && r.startedAt == _candidates[room])) {
      invalidate();
      throw const SessionControlFailure(
        'Selected host changed. Reopen from Home.',
      );
    }
    _remember(room); // Pin before any asynchronous pairing lookup.
    await _select(room);
  }

  @override
  Future<SessionStopCapability> returnToChild() async {
    if (_child == null) {
      throw const SessionControlFailure('Recovery not ready. Return Home.');
    }
    await _select(_child!);
    final status = await _controls.inspect(_peer!, _child!);
    _check();
    return status; // Newly leased token only. Never used by recovery itself.
  }

  @override
  void checkCurrent() => _check();

  @override
  void invalidate() {
    if (_invalid) return;
    _invalid = true;
    _invalidations.add(null);
  }

  @override
  void dispose() {
    invalidate();
    unawaited(_status?.cancel());
    unawaited(_discovery?.cancel());
    _rooms.clear();
    _candidates.clear();
    unawaited(_invalidations.close());
  }
}
