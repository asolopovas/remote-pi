// ActionsRepository — Plan/28 typed app actions.
//
// Wraps the active `IChannel` exposed by [ConnectionManager] and turns
// the per-action wire dance into a typed Future<void> /
// Future<ModelsCatalogue>. Each call:
//   1. mints a UUIDv7 request id
//   2. registers a Completer in the pending map
//   3. sends the ClientMessage
//   4. resolves the Completer when the matching `action_ok` /
//      `action_error` / `models_list` arrives (or fails with
//      [ActionFailure] on disconnect / timeout)
//
// `list_models` results are cached per active (peer, room) for the
// session. Three cache-invalidation paths:
//
//   1. Local `setModel` — caller knows the cache is stale, drops it.
//   2. External `room_meta_updated` carrying a different model than
//      we last knew (Wave D: another app paired with this Pi, or the
//      TUI's `/model` switched it). Detected by listening to the
//      ConnectionManager's `roomsStream`.
//   3. Manual `forceRefresh: true` from the picker's pull-to-refresh.
//
// The repository also exposes [activeRoomMeta] — a typed snapshot of
// `(model, thinking)` for the active room — so the QuickActions
// ViewModel can hydrate the segmented control on first open instead
// of starting null.

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

/// Reply for [ActionsRepository.listModels]. Captures both the catalogue
/// and the model the Pi reports as active right now.
class ModelsCatalogue {
  final List<WireModel> models;
  final WireModel? current;
  const ModelsCatalogue({required this.models, this.current});
}

/// Plan/28 Wave D — snapshot of the active room's meta, as broadcast
/// by the relay. Forwarded by [ActionsRepository.activeRoomMeta] so
/// the QuickActions ViewModel can hydrate its current model / thinking
/// without a round-trip.
class ActiveRoomMeta {
  /// Standard-b64 epk of the active peer, or `null` when no peer is
  /// active (offline, between switches, etc.). Helps a consumer ignore
  /// transient empty snapshots vs. honest "we're not paired" state.
  final String? peerEpk;

  /// Pi-side room id this snapshot describes — defaults to `'main'`.
  final String roomId;

  /// Display model name from `meta.model` (e.g. "Claude Opus 4.7").
  /// `null` until the Pi publishes it (or while disconnected).
  final String? model;

  /// Current thinking level from `meta.thinking`. Forward-compat — the
  /// relay does not yet flatten this field, so until the relay update
  /// ships this is always `null` in production. Kept on the API
  /// surface so the app stack lights up the moment the relay catches
  /// up, no further app changes required.
  final ThinkingLevel? thinking;
  const ActiveRoomMeta({
    this.peerEpk,
    this.roomId = 'main',
    this.model,
    this.thinking,
  });

  @override
  bool operator ==(Object other) =>
      other is ActiveRoomMeta &&
      other.peerEpk == peerEpk &&
      other.roomId == roomId &&
      other.model == model &&
      other.thinking == thinking;

  @override
  int get hashCode => Object.hash(peerEpk, roomId, model, thinking);
}

/// Typed failure thrown by [ActionsRepository] when an action cannot
/// complete. UI layer renders [message] as a snackbar.
class ActionFailure implements Exception {
  final String message;
  const ActionFailure(this.message);

  @override
  String toString() => 'ActionFailure: $message';
}

abstract class IActionsRepository extends Repository {
  Future<void> compact();
  Future<void> newSession();
  Future<void> setModel(String provider, String modelId);
  Future<void> setThinking(ThinkingLevel level);

  /// Fetches the model catalogue. When [forceRefresh] is `false`
  /// (default) returns the cached catalogue for the current
  /// (peer, room) session if one exists; otherwise hits the Pi.
  Future<ModelsCatalogue> listModels({bool forceRefresh = false});

  /// Snapshot of the active room's meta. Recomputed on every rooms
  /// snapshot and on every connection-status change.
  ActiveRoomMeta get activeRoomMeta;

  /// Stream of [activeRoomMeta] snapshots — deduplicated by equality
  /// so consumers don't rebuild on no-op emits.
  Stream<ActiveRoomMeta> get activeRoomMetaStream;
}

/// Captures a one-way UI lease. A closed lease can never adopt a new session.
abstract class IActionScopeSource {
  bool Function() captureActionScope();
}

class ActionsRepository extends Repository
    implements IActionsRepository, IActionScopeSource {
  final ConnectionManager _conn;
  final Duration _timeout;

  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<Object?>? _msgSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  IChannel? _channel;
  int _channelGeneration = 0;

  final Map<String, _Pending> _pending = {};
  final Map<String, ModelsCatalogue> _modelsCache = {};
  final Map<String, int> _catalogueGeneration = {};
  final Map<String, bool Function()> _cacheScopes = {};
  void _invalidate(String key) {
    _modelsCache.remove(key);
    _cacheScopes.remove(key);
    _catalogueGeneration[key] = (_catalogueGeneration[key] ?? 0) + 1;
  }

  @override
  bool Function() captureActionScope() {
    final ch = _conn.channel;
    final key = _sessionKey();
    final epoch = _conn.roomSelectionEpoch;
    final generation = _channelGeneration;
    final epk = _conn.activePeer?.remoteEpk;
    final room = _conn.activeRoomId;
    final info = epk == null
        ? null
        : _conn.roomsFor(epk).where((r) => r.roomId == room).firstOrNull;
    final roomGuard = epk == null
        ? () => false
        : _conn.roomActionGuard(epk, room, info?.startedAt);
    var invalid = false;
    return () {
      invalid =
          invalid ||
          ch == null ||
          generation != _channelGeneration ||
          !identical(ch, _conn.channel) ||
          !identical(ch, _channel) ||
          key != _sessionKey() ||
          epoch != _conn.roomSelectionEpoch ||
          !roomGuard();
      return !invalid;
    };
  }

  /// Plan/28 Wave D — last model name we observed via `roomsStream`
  /// per session key. Lets us detect "the model changed externally"
  /// without invalidating the cache on the local round-trip we just
  /// initiated (which has already cleared the cache directly).
  final Map<String, String?> _lastKnownModelName = {};

  ActiveRoomMeta _activeRoomMeta = const ActiveRoomMeta();
  final _activeRoomMetaController =
      StreamController<ActiveRoomMeta>.broadcast();

  ActionsRepository(
    this._conn, {
    Duration timeout = const Duration(seconds: 15),
  }) : _timeout = timeout {
    _statusSub = _conn.statusStream.listen(_onStatus);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _onStatus(_conn.status);
    // Seed the meta snapshot synchronously so an early caller sees
    // whatever the ConnectionManager already cached at construction.
    _refreshActiveRoomMeta();
  }

  // ---------------------------------------------------------------------------
  // Wire glue
  // ---------------------------------------------------------------------------

  void _onStatus(ConnectionStatus s) {
    final next = s is StatusOnline ? s.channel : null;
    if (!identical(next, _channel)) {
      _channelGeneration++;
      _failAllPending(next == null ? 'disconnected' : 'session changed');
      _modelsCache.clear();
      _cacheScopes.clear();
    }
    _msgSub?.cancel();
    _msgSub = null;
    _channel = next;
    if (next != null) {
      void ended() {
        if (!identical(next, _channel)) return;
        _channelGeneration++;
        _failAllPending('disconnected');
        _channel = null;
        _modelsCache.clear();
        _cacheScopes.clear();
      }

      if (next is IScopedActionChannel) {
        _msgSub = (next as IScopedActionChannel).actionReplies.listen(
          (reply) {
            if (!identical(next, _channel)) return;
            _onMessage(
              reply.message,
              peer: reply.peer,
              room: reply.room,
              scoped: true,
            );
          },
          onError: (Object _, StackTrace _) => ended(),
          onDone: ended,
        );
      } else {
        _msgSub = next.serverMessages.listen(
          (msg) {
            if (identical(next, _channel)) _onMessage(msg);
          },
          onError: (Object _, StackTrace _) => ended(),
          onDone: ended,
        );
      }
    }
    _refreshActiveRoomMeta();
  }

  void _onRooms(Map<String, List<RoomInfo>> _) {
    for (final id in _pending.keys.toList()) {
      final p = _pending[id]!;
      if (!p.current()) {
        _settle(
          id,
          error: ActionFailure(
            p.kind == 'model_set'
                ? 'Session changed. Model change outcome unknown. Reload models.'
                : 'session changed',
          ),
        );
      }
    }
    _refreshActiveRoomMeta();
  }

  void _settle(String id, {Object? value, ActionFailure? error}) {
    final p = _pending.remove(id);
    if (p == null) return;
    p.timeout.cancel();
    if (error != null) {
      p.completer.completeError(error);
    } else {
      p.completer.complete(value);
    }
  }

  void _onMessage(
    ServerMessage msg, {
    String? peer,
    String? room,
    bool scoped = false,
  }) {
    final id = switch (msg) {
      ActionOk(:final inReplyTo) => inReplyTo,
      ActionError(:final inReplyTo) => inReplyTo,
      ModelsList(:final inReplyTo) => inReplyTo,
      ErrorMessage(:final inReplyTo) => inReplyTo,
      _ => null,
    };
    final p = _pending[id];
    if (p == null) return;
    if (!p.current()) {
      _settle(
        id!,
        error: ActionFailure(
          p.kind == 'model_set'
              ? 'Session changed. Model change outcome unknown. Reload models.'
              : 'session changed',
        ),
      );
      return;
    }
    if (scoped &&
        (peer == null ||
            p.peer == null ||
            toStandardB64(peer) != toStandardB64(p.peer!) ||
            room != p.room)) {
      return;
    }
    switch (msg) {
      case ActionOk(:final rawAction):
        if (rawAction != p.kind || p.kind == 'list_models') return;
        _settle(id!);
      case ActionError(:final rawAction, :final error):
        if (rawAction != p.kind) return;
        _settle(
          id!,
          error: ActionFailure(error.isEmpty ? 'action failed' : error),
        );
      case ErrorMessage(:final message):
        // Generic errors require authenticated outer scope, never just a UUID.
        if (!scoped) return;
        _settle(id!, error: ActionFailure(message));
      case ModelsList(:final models, :final current):
        if (p.kind != 'list_models') return;
        _settle(
          id!,
          value: ModelsCatalogue(models: models, current: current),
        );
      default:
        break;
    }
  }

  void _failAllPending(String reason) {
    if (_pending.isEmpty) return;
    final snapshot = List<_Pending>.of(_pending.values);
    _pending.clear();
    for (final p in snapshot) {
      p.timeout.cancel();
      if (!p.completer.isCompleted) {
        p.completer.completeError(
          ActionFailure(
            p.kind == 'model_set'
                ? '$reason. Model change outcome unknown. Reload models.'
                : reason,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Active room meta + cache invalidation
  // ---------------------------------------------------------------------------

  void _refreshActiveRoomMeta() {
    final peer = _conn.activePeer;
    final epk = peer?.remoteEpk;
    final roomId = _conn.activeRoomId;

    RoomInfo? active;
    if (epk != null) {
      final rooms = _conn.roomsFor(epk);
      for (final r in rooms) {
        if (r.roomId == roomId) {
          active = r;
          break;
        }
      }
    }

    final next = ActiveRoomMeta(
      peerEpk: epk,
      roomId: roomId,
      model: active?.model,
      thinking: active?.thinking,
    );

    // Plan/28 Wave D — detect external model changes. The local
    // `setModel` path already drops the cache directly; here we only
    // care about transitions of model name learned via room broadcasts.
    final key = '$epk|$roomId';
    final previousModel = _lastKnownModelName[key];
    final hadPreviousKnowledge = _lastKnownModelName.containsKey(key);
    if (hadPreviousKnowledge && previousModel != next.model) {
      _invalidate(key);
    }
    _lastKnownModelName[key] = next.model;

    if (next == _activeRoomMeta) return;
    _activeRoomMeta = next;
    if (!_activeRoomMetaController.isClosed) {
      _activeRoomMetaController.add(next);
    }
  }

  @override
  ActiveRoomMeta get activeRoomMeta => _activeRoomMeta;

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      _activeRoomMetaController.stream;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Future<void> compact() async {
    await _dispatch<void>((id) => SessionCompact(id: id));
  }

  @override
  Future<void> newSession() async {
    await _dispatch<void>((id) => SessionNew(id: id));
  }

  @override
  Future<void> setModel(String provider, String modelId) async {
    final key = _sessionKey();
    _invalidate(key);
    await _dispatch<void>(
      (id) => ModelSet(id: id, provider: provider, modelId: modelId),
    );
    // Invalidate the cached catalogue so the next picker open reflects
    // the new `current` highlight.
    _invalidate(key);
  }

  @override
  Future<void> setThinking(ThinkingLevel level) async {
    await _dispatch<void>((id) => ThinkingSet(id: id, level: level));
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    final key = _sessionKey();
    if (!forceRefresh) {
      final cached = _modelsCache[key];
      if (cached != null && (_cacheScopes[key]?.call() ?? false)) return cached;
      _modelsCache.remove(key);
    }
    final current = captureActionScope();
    final generation = (_catalogueGeneration[key] ?? 0) + 1;
    _catalogueGeneration[key] = generation;
    final result = await _dispatch<ModelsCatalogue>((id) => ListModels(id: id));
    if (!current() || generation != _catalogueGeneration[key]) {
      throw const ActionFailure('Models changed. Reload models.');
    }
    _modelsCache[key] = result;
    _cacheScopes[key] = current;
    return result;
  }

  Future<T> _dispatch<T>(ClientMessage Function(String id) builder) async {
    final ch = _channel;
    if (ch == null || !identical(ch, _conn.channel)) {
      throw const ActionFailure('offline');
    }
    final current = captureActionScope();
    if (!current()) {
      throw const ActionFailure('Session changed. Reopen model picker.');
    }
    final id = '$actionRequestPrefix${uuid7()}';
    final message = builder(id);
    final kind = message.toJson()['type'] as String;
    final completer = Completer<dynamic>();
    final timer = Timer(_timeout, () {
      _settle(
        id,
        error: ActionFailure(
          kind == 'model_set'
              ? 'Model change outcome unknown. Reload models before choosing again.'
              : 'timeout',
        ),
      );
    });
    _pending[id] = _Pending(
      completer: completer,
      timeout: timer,
      current: current,
      kind: kind,
      peer: _conn.activePeer?.remoteEpk,
      room: _conn.activeRoomId,
    );
    // Attach the reply waiter BEFORE send. The end-to-end deadline must not
    // wait for send; Future.sync observes synchronous and late async failures.
    final result = completer.future.then((value) => value as T);
    unawaited(
      Future<void>.sync(() => ch.send(message)).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _settle(
            id,
            error: ActionFailure(
              kind == 'model_set'
                  ? 'Model change outcome unknown. Reload models before choosing again.'
                  : 'Send failed: $error',
            ),
          );
        },
      ),
    );
    return result;
  }

  String _sessionKey() {
    final epk = _conn.activePeer?.remoteEpk ?? '';
    final room = _conn.activeRoomId;
    return '$epk|$room';
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _msgSub?.cancel();
    _roomsSub?.cancel();
    _failAllPending('disposed');
    _modelsCache.clear();
    _cacheScopes.clear();
    _lastKnownModelName.clear();
    _activeRoomMetaController.close();
    super.dispose();
  }
}

class _Pending {
  final Completer<dynamic> completer;
  final Timer timeout;
  final bool Function() current;
  final String kind;
  final String? peer;
  final String room;
  _Pending({
    required this.completer,
    required this.timeout,
    required this.current,
    required this.kind,
    required this.peer,
    required this.room,
  });
}
