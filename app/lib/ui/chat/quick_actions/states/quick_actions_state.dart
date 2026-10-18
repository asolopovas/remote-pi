import 'package:app/protocol/protocol.dart';

/// Plan/28 Wave C — state for the Quick Actions bottom sheet ViewModel.
///
/// The sheet only needs to know "is anything in-flight?" plus the last
/// resolved current model / thinking level so the picker rows highlight
/// correctly. Errors are pushed via [QuickActionsViewModel.errors] for
/// snackbars and don't live on the state class — the sheet stays usable
/// after a failure.
sealed class QuickActionsState {
  final ThinkingLevel? currentThinking;
  final WireModel? currentModel;
  /// Plan/28 Wave D — display name from `room_meta.model`. Survives
  /// across picker opens and is shown in the bottom-sheet Model row
  /// when the structured [currentModel] hasn't been loaded yet (the
  /// catalogue is fetched lazily; meanwhile the room broadcast already
  /// tells us which model is in use).
  final String? currentModelName;
  const QuickActionsState({
    this.currentThinking,
    this.currentModel,
    this.currentModelName,
  });
}

class QuickActionsIdle extends QuickActionsState {
  const QuickActionsIdle({
    super.currentThinking,
    super.currentModel,
    super.currentModelName,
  });

  @override
  bool operator ==(Object other) =>
      other is QuickActionsIdle &&
      other.currentThinking == currentThinking &&
      other.currentModel == currentModel &&
      other.currentModelName == currentModelName;

  @override
  int get hashCode =>
      Object.hash(currentThinking, currentModel, currentModelName);
}

class QuickActionsBusy extends QuickActionsState {
  /// Which action is currently in flight — drives the spinner placement.
  /// Use [ActionName.modelSet] for both model and thinking changes when
  /// the picker fires them; the sheet doesn't need finer granularity
  /// than that.
  final ActionName action;
  const QuickActionsBusy({
    required this.action,
    super.currentThinking,
    super.currentModel,
    super.currentModelName,
  });

  @override
  bool operator ==(Object other) =>
      other is QuickActionsBusy &&
      other.action == action &&
      other.currentThinking == currentThinking &&
      other.currentModel == currentModel &&
      other.currentModelName == currentModelName;

  @override
  int get hashCode =>
      Object.hash(action, currentThinking, currentModel, currentModelName);
}
