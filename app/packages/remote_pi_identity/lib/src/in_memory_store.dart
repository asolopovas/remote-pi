import 'dart:async';

import 'owner_identity.dart';
import 'owner_identity_store.dart';

/// In-memory implementation of [OwnerIdentityStore] for tests and fakes.
///
/// Behaves like a perfectly-cooperative platform: `save` immediately
/// pushes through `watch`, `delete` clears the cache, `isSyncAvailable`
/// is configurable. Not thread-safe across isolates.
class InMemoryOwnerIdentityStore implements OwnerIdentityStore {
  OwnerIdentity? _current;
  bool _syncAvailable;
  final _controller = StreamController<OwnerIdentity>.broadcast();

  InMemoryOwnerIdentityStore({
    OwnerIdentity? initial,
    bool syncAvailable = true,
  })  : _current = initial,
        _syncAvailable = syncAvailable;

  /// Toggle sync availability at runtime — useful to exercise the
  /// "user just disabled iCloud Keychain" branch in tests.
  set syncAvailable(bool value) => _syncAvailable = value;

  @override
  Future<OwnerIdentity?> load() async {
    if (!_syncAvailable) {
      throw IdentityStoreError.syncUnavailable('test fixture: syncAvailable=false');
    }
    return _current;
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    if (!_syncAvailable) {
      throw IdentityStoreError.syncUnavailable('test fixture: syncAvailable=false');
    }
    _current = identity;
    _controller.add(identity);
  }

  @override
  Stream<OwnerIdentity> watch() => _controller.stream;

  @override
  Future<void> delete() async {
    if (!_syncAvailable) {
      throw IdentityStoreError.syncUnavailable('test fixture: syncAvailable=false');
    }
    _current = null;
  }

  @override
  Future<bool> isSyncAvailable() async => _syncAvailable;

  /// Releases the underlying stream controller. Tests should call this
  /// in `tearDown` so leaked subscribers don't pin the controller.
  Future<void> dispose() => _controller.close();
}
