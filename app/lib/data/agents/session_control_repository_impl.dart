import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

class _StopLease {
  _StopLease(this.peer, this.room, this.channel, this.epoch, this.startedAt);
  final String peer, room;
  final int? startedAt;
  final IChannel channel;
  final int epoch;
  final createdAt = DateTime.now();
}

/// Pins the current transport and room; never switches sessions or retries Stop.
class SessionControlRepositoryImpl extends SessionControlRepository {
  SessionControlRepositoryImpl(
    this._conn, {
    this.timeout = const Duration(seconds: 8),
    this.stopTimeout = const Duration(seconds: 15),
  });
  final ConnectionManager _conn;
  final Duration timeout, stopTimeout;
  final _leases = <String, _StopLease>{};
  final _pending = <void Function()>{};
  bool _disposed = false;

  bool _valid(_StopLease lease) =>
      !_disposed &&
      identical(_conn.channel, lease.channel) &&
      _conn.activePeer != null &&
      toStandardB64(_conn.activePeer!.remoteEpk) == toStandardB64(lease.peer) &&
      _conn.activeRoomId == lease.room &&
      _conn.roomSelectionEpoch == lease.epoch &&
      _conn.isRoomLive(lease.peer, lease.room) &&
      _conn
          .roomsFor(lease.peer)
          .any((r) => r.roomId == lease.room && r.startedAt == lease.startedAt);

  _StopLease _capture(String peer, String room) {
    final channel = _conn.channel;
    if (channel == null) throw const SessionControlFailure('Agent offline.');
    final incarnation = _conn
        .roomsFor(peer)
        .where((r) => r.roomId == room)
        .firstOrNull
        ?.startedAt;
    final lease = _StopLease(
      peer,
      room,
      channel,
      _conn.roomSelectionEpoch,
      incarnation,
    );
    if (!_valid(lease)) {
      throw const SessionControlFailure('Agent changed or disconnected.');
    }
    return lease;
  }

  @override
  Future<SessionStopCapability> inspect(String peer, String room) async {
    final lease = _capture(peer, room);
    final result = await _request(
      lease,
      (id) => SessionControlStatus(id, room),
    );
    if (!_valid(lease)) {
      throw const SessionControlFailure('Agent changed or disconnected.');
    }
    final status = result as SessionControlStatusResult;
    _leases.removeWhere(
      (_, entry) =>
          !_valid(entry) ||
          DateTime.now().difference(entry.createdAt) >=
              const Duration(seconds: 30),
    );
    if (status.token != null) {
      if (_leases.length >= 64) {
        throw const SessionControlFailure(
          'Too many open confirmations. Reopen agent info.',
        );
      }
      _leases[status.token!] = lease;
    }
    return SessionStopCapability(
      peer: peer,
      room: room,
      canStop: status.canStop,
      token: status.token,
      reason: status.reason,
      access: status.access,
      launchingHost: status.launchingHost,
    );
  }

  @override
  Future<SessionStopOutcome> stop(SessionStopCapability capability) async {
    final lease = _leases.remove(
      capability.token,
    ); // Consume before sending; no retry.
    if (lease == null ||
        !capability.canStop ||
        lease.peer != capability.peer ||
        lease.room != capability.room ||
        !_valid(lease) ||
        DateTime.now().difference(lease.createdAt) >=
            const Duration(seconds: 30)) {
      throw const SessionControlFailure(
        'Confirmation expired. Reopen agent info.',
      );
    }
    final result =
        await _request(
              lease,
              (id) => SessionStop(id, lease.room, capability.token!),
              stopping: true,
            )
            as SessionStopResult;
    return result.state == 'stopped'
        ? SessionStopOutcome.stopped
        : SessionStopOutcome.requested;
  }

  Future<ServerMessage> _request(
    _StopLease lease,
    ClientMessage Function(String) create, {
    bool stopping = false,
  }) async {
    if (!_valid(lease)) {
      throw const SessionControlFailure('Agent changed or disconnected.');
    }
    final id = '$sessionControlRequestPrefix${uuid7()}';
    final completion = Completer<ServerMessage>();
    void fail(String message) {
      if (!completion.isCompleted) {
        completion.completeError(
          SessionControlFailure(message, outcomeUnknown: stopping),
        );
      }
    }

    void invalidate() {
      if (!_valid(lease)) {
        fail(
          stopping
              ? 'Stop result unknown. Refresh sessions.'
              : 'Agent changed or disconnected.',
        );
      }
    }

    final timer = Timer(
      stopping ? stopTimeout : timeout,
      () => fail(
        stopping
            ? 'Stop result unknown. Refresh sessions.'
            : 'Update the host to stop agents remotely.',
      ),
    );
    final messages = lease.channel.serverMessages.listen(
      (message) {
        if (!_valid(lease)) {
          invalidate();
          return;
        }
        if (message is ErrorMessage) {
          if (message is! ScopedPeerError ||
              toStandardB64(message.peer) != toStandardB64(lease.peer) ||
              message.room != lease.room ||
              message.inReplyTo != id) {
            return;
          }
          if (!completion.isCompleted) {
            completion.completeError(SessionControlFailure(message.message));
          }
          return;
        }
        final matches = stopping
            ? message is SessionStopResult &&
                  message.inReplyTo == id &&
                  message.roomId == lease.room
            : message is SessionControlStatusResult &&
                  message.inReplyTo == id &&
                  message.roomId == lease.room;
        if (matches && !completion.isCompleted) completion.complete(message);
      },
      onDone: () => fail(
        stopping
            ? 'Stop result unknown. Refresh sessions.'
            : 'Agent disconnected.',
      ),
      onError: (Object _) => fail(
        stopping
            ? 'Stop result unknown. Refresh sessions.'
            : 'Agent disconnected.',
      ),
    );
    final status = _conn.statusStream.listen((_) => invalidate());
    final rooms = _conn.roomsStream.listen((_) => invalidate());
    void cancel() => fail('Agent controls closed.');
    _pending.add(cancel);
    try {
      if (!_valid(lease)) {
        throw const SessionControlFailure('Agent changed or disconnected.');
      }
      unawaited(
        Future<void>.sync(() => lease.channel.send(create(id))).catchError((
          Object _,
        ) {
          fail(
            stopping
                ? 'Stop result unknown. Refresh sessions.'
                : 'Agent disconnected.',
          );
        }),
      );
      return await completion.future;
    } finally {
      timer.cancel();
      _pending.remove(cancel);
      await messages.cancel();
      await status.cancel();
      await rooms.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _leases.clear();
    for (final cancel in _pending.toList()) {
      cancel();
    }
    _pending.clear();
  }
}
