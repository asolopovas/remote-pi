import 'dart:async';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/states/quick_actions_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/28 Wave C — drives the Quick Actions bottom sheet and its
/// Model sub-picker. Holds the last-resolved "current" pair (model /
/// thinking level) so the picker can highlight without waiting for
/// another round-trip.
///
/// Plan/28 Wave D — also hydrates the current thinking / model name
/// from [IActionsRepository.activeRoomMetaStream] so the bottom sheet
/// reflects the Pi's real state on first open (instead of starting
/// `null`). External model changes (other paired apps or the TUI's
/// `/model`) come in through the same stream.
///
/// Errors raised by [IActionsRepository] are forwarded to [errors] so
/// the page can surface them as SnackBars. State stays usable after a
/// failure — the next tap retries.
class QuickActionsViewModel extends ViewModel<QuickActionsState> {
  final IActionsRepository _repo;
  final _errorController = StreamController<String>.broadcast();
  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _disposed = false;
  late final bool Function() _scope;
  int _modelRevision = 0;
  int _loadRevision = 0;

  static const sessionChangedMessage =
      'Session changed. Return to sessions and reopen this chat.';

  /// Read-only status of this VM's original authority; never renews it.
  bool get hasValidScope => _scope();

  void _checkScope() {
    if (!_scope()) {
      throw const ActionFailure(sessionChangedMessage);
    }
  }

  void _report(Object error) {
    if (!_disposed) {
      _errorController.add(
        error is ActionFailure ? error.message : 'Action failed: $error',
      );
    }
  }

  QuickActionsViewModel(this._repo) : super(const QuickActionsIdle()) {
    // Plan/28 Wave D — seed from the repo's current snapshot before
    // anything is shown so the first build already has the right
    // highlight (instead of a flash of "null" while the stream
    // delivers its first event).
    final source = _repo;
    _scope = source is IActionScopeSource
        ? (source as IActionScopeSource).captureActionScope()
        : () => true;
    _adoptMeta(_repo.activeRoomMeta);
    _metaSub = _repo.activeRoomMetaStream.listen(_adoptMeta);
  }

  /// Snackbar feed: one string per failure. The page listens with a
  /// `StreamSubscription` so a failed action can show a toast without
  /// blocking the sheet itself.
  Stream<String> get errors => _errorController.stream;

  ThinkingLevel? get currentThinking => state.currentThinking;
  WireModel? get currentModel => state.currentModel;
  String? get currentModelName => state.currentModelName;

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> compact() async {
    await _runVoid(ActionName.sessionCompact, _repo.compact);
  }

  Future<void> newSession() async {
    await _runVoid(ActionName.sessionNew, _repo.newSession);
  }

  Future<void> setModel(WireModel model) async {
    _checkScope();
    if (_disposed || state is QuickActionsBusy) {
      throw const ActionFailure('Action already in progress.');
    }
    _modelRevision++;
    // Optimistic highlight — flip the current model immediately so the
    // picker row reflects the tap before the round-trip resolves.
    final previous = state.currentModel;
    final previousName = state.currentModelName;
    _emitIfAlive(
      QuickActionsBusy(
        action: ActionName.modelSet,
        currentModel: model,
        currentModelName: model.name,
        currentThinking: state.currentThinking,
      ),
    );
    try {
      await _repo.setModel(model.provider, model.id);
      _checkScope();
      _modelRevision++;
      _emitIfAlive(
        QuickActionsIdle(
          currentModel: model,
          currentModelName: model.name,
          currentThinking: state.currentThinking,
        ),
      );
    } catch (e) {
      // Revert optimistic highlight on failure.
      _emitIfAlive(
        QuickActionsIdle(
          currentModel: previous,
          currentModelName: previousName,
          currentThinking: state.currentThinking,
        ),
      );
      _report(e);
      rethrow;
    }
  }

  Future<void> setThinking(ThinkingLevel level) async {
    _checkScope();
    if (state is QuickActionsBusy) {
      throw const ActionFailure('Action already in progress.');
    }
    final previous = state.currentThinking;
    _emitIfAlive(
      QuickActionsBusy(
        action: ActionName.thinkingSet,
        currentThinking: level,
        currentModel: state.currentModel,
        currentModelName: state.currentModelName,
      ),
    );
    try {
      await _repo.setThinking(level);
      _checkScope();
      _emitIfAlive(
        QuickActionsIdle(
          currentThinking: level,
          currentModel: state.currentModel,
          currentModelName: state.currentModelName,
        ),
      );
    } catch (e) {
      _emitIfAlive(
        QuickActionsIdle(
          currentThinking: previous,
          currentModel: state.currentModel,
          currentModelName: state.currentModelName,
        ),
      );
      _report(e);
      rethrow;
    }
  }

  /// Hits the Pi (or returns the cached catalogue) for the model
  /// picker. Throws [ActionFailure] on disconnect / timeout — the
  /// picker widget catches and renders an error placeholder.
  Future<ModelsCatalogue> loadModels({bool forceRefresh = false}) async {
    _checkScope();
    final revision = _modelRevision;
    final load = ++_loadRevision;
    try {
      final catalogue = await _repo.listModels(forceRefresh: forceRefresh);
      _checkScope();
      if (_disposed ||
          revision != _modelRevision ||
          load != _loadRevision ||
          state is QuickActionsBusy) {
        throw const ActionFailure('Models changed. Reload models.');
      }
      // Adopt the Pi's "current" answer; only overwrite when present so
      // a stale cache entry (current=null) doesn't clobber a value we
      // already learned via setModel.
      if (catalogue.current != null) {
        _emitIfAlive(
          QuickActionsIdle(
            currentModel: catalogue.current,
            currentModelName: catalogue.current?.name ?? state.currentModelName,
            currentThinking: state.currentThinking,
          ),
        );
      }
      return catalogue;
    } catch (e) {
      _report(e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------

  /// Plan/28 Wave D — react to a room-meta snapshot. Adopts the
  /// thinking level (always — the relay is the source of truth) and
  /// the model name (when present). Leaves the structured
  /// [currentModel] alone because the meta only carries a display
  /// name, not the full [WireModel]; the picker can call
  /// [loadModels] when it needs the structured record.
  void _adoptMeta(ActiveRoomMeta meta) {
    if (_disposed || !_scope()) return;
    final cur = state;
    // Compose the next state preserving the busy-action flag so an
    // in-flight call doesn't lose its spinner mid-update.
    final nextThinking = meta.thinking ?? cur.currentThinking;
    final nextModelName = meta.model ?? cur.currentModelName;
    // If the meta's model differs from the structured `currentModel`
    // name (external switch), drop the structured model so the picker
    // re-fetches on next open.
    WireModel? nextModel = cur.currentModel;
    if (meta.model != null &&
        cur.currentModel != null &&
        cur.currentModel!.name != meta.model) {
      nextModel = null;
    }

    QuickActionsState next;
    if (cur is QuickActionsBusy) {
      next = QuickActionsBusy(
        action: cur.action,
        currentThinking: nextThinking,
        currentModel: nextModel,
        currentModelName: nextModelName,
      );
    } else {
      next = QuickActionsIdle(
        currentThinking: nextThinking,
        currentModel: nextModel,
        currentModelName: nextModelName,
      );
    }
    if (next == cur) return;
    emit(next);
  }

  Future<void> _runVoid(ActionName action, Future<void> Function() body) async {
    _checkScope();
    _emitIfAlive(
      QuickActionsBusy(
        action: action,
        currentThinking: state.currentThinking,
        currentModel: state.currentModel,
        currentModelName: state.currentModelName,
      ),
    );
    try {
      await body();
      _checkScope();
      _emitIfAlive(
        QuickActionsIdle(
          currentThinking: state.currentThinking,
          currentModel: state.currentModel,
          currentModelName: state.currentModelName,
        ),
      );
    } catch (e) {
      _emitIfAlive(
        QuickActionsIdle(
          currentThinking: state.currentThinking,
          currentModel: state.currentModel,
          currentModelName: state.currentModelName,
        ),
      );
      _report(e);
      rethrow;
    }
  }

  void _emitIfAlive(QuickActionsState next) {
    if (_disposed) return;
    if (!_scope()) {
      // This VM is permanently bound to its source modal, never adopted by B.
      emit(const QuickActionsIdle());
      return;
    }
    emit(next);
  }

  @override
  void dispose() {
    _disposed = true;
    _metaSub?.cancel();
    _errorController.close();
    super.dispose();
  }
}
