import 'package:app/protocol/protocol.dart';

/// Ephemeral display-only authority for one exact routing room on one socket.
/// Invalidation keeps the watermark, but only a snapshot can recover authority.
class RoomDisplayAuthority {
  static const maxIncarnations = 64;
  final Set<String> _retiredEpochs = {};
  RoomDisplay? _highWater;
  RoomDisplay? _verified;
  bool _closed = false;

  RoomDisplay? get verified => _verified;

  void invalidate() => _verified = null;

  RoomDisplay? snapshot(RoomDisplay? value) {
    if (_closed) return null;
    if (value == null) {
      invalidate();
      return null;
    }
    if (_retiredEpochs.contains(value.epoch)) return _verified;
    final previous = _highWater;
    if (previous != null) {
      if (previous.epoch == value.epoch) {
        if (!previous.sameIncarnation(value) ||
            value.revision < previous.revision ||
            (value.revision == previous.revision && value != previous)) {
          return _verified;
        }
      } else {
        // Never evict a retired epoch: that would permit A→B→A resurrection.
        if (_retiredEpochs.length >= maxIncarnations - 1) {
          _closed = true;
          invalidate();
          return null;
        }
        _retiredEpochs.add(previous.epoch);
      }
    }
    _highWater = value;
    return _verified = value;
  }

  RoomDisplay? update(RoomDisplay? value) {
    if (value == null) {
      invalidate();
      return null;
    }
    final previous = _highWater;
    if (!_closed &&
        _verified != null &&
        previous != null &&
        previous.sameIncarnation(value) &&
        value.revision > previous.revision) {
      _highWater = value;
      _verified = value;
    }
    return _verified;
  }
}
