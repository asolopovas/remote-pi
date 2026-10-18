import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart' show listEquals;

sealed class SettingsState {
  const SettingsState();
}

class SettingsLoading extends SettingsState {
  const SettingsLoading();
}

class SettingsNoPeer extends SettingsState {
  const SettingsNoPeer();
}

/// One or more peers paired. Settings is config-only now: rename, revoke.
/// The "currently active" pointer lives in [Preferences] and is consumed
/// by `/chat` — Settings does not surface it.
class SettingsList extends SettingsState {
  final List<PeerRecord> peers;

  const SettingsList({required this.peers});

  @override
  bool operator ==(Object other) =>
      other is SettingsList && listEquals(other.peers, peers);

  @override
  int get hashCode => Object.hashAll(peers);
}
