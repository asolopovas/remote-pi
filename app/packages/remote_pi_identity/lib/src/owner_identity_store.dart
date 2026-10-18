import 'owner_identity.dart';

/// Thrown by [OwnerIdentityStore] when it cannot fulfill a request.
///
/// Two flavors:
/// - [SyncUnavailable]: the platform's key-sync subsystem is off
///   (iCloud Keychain disabled, no Google account / backup disabled).
///   Callers should surface the platform-specific config instructions
///   from the README, not retry blindly.
/// - [PlatformFailure]: a low-level error came back from the native
///   side (`code` matches the platform error code; `message` is human
///   readable). Treat as fatal — corruption, missing entitlement, etc.
sealed class IdentityStoreError implements Exception {
  const IdentityStoreError._();

  factory IdentityStoreError.syncUnavailable(String reason) = SyncUnavailable;
  factory IdentityStoreError.platform(String code, String message) =
      PlatformFailure;
}

final class SyncUnavailable extends IdentityStoreError {
  final String reason;
  const SyncUnavailable(this.reason) : super._();

  @override
  String toString() => 'SyncUnavailable: $reason';
}

final class PlatformFailure extends IdentityStoreError {
  final String code;
  final String message;
  const PlatformFailure(this.code, this.message) : super._();

  @override
  String toString() => 'PlatformFailure($code): $message';
}

/// Abstract store backed by platform-native synced storage.
///
/// Implementations:
/// - [MethodChannelOwnerIdentityStore] (production, talks to iOS/Android)
/// - [InMemoryOwnerIdentityStore] (tests, fakes)
abstract class OwnerIdentityStore {
  /// Returns the currently-persisted identity, or null on first run.
  ///
  /// Throws [SyncUnavailable] if the platform sync subsystem is off.
  /// Throws [PlatformFailure] on lower-level errors (corruption etc).
  Future<OwnerIdentity?> load();

  /// Persists [identity] and triggers platform sync to other devices.
  ///
  /// Throws [SyncUnavailable] / [PlatformFailure] same as [load].
  Future<void> save(OwnerIdentity identity);

  /// Emits whenever the platform sync surface reports a new value.
  ///
  /// Hot stream (broadcast). Subscribers should be prepared for
  /// emissions at any time, including a single emission shortly after
  /// `listen()` if a value is already cached locally.
  ///
  /// On Android, "new value" arrives only on restore-to-new-device —
  /// live sync between active devices is not supported by Block Store
  /// (see plugin README's "Known limitations" section).
  Stream<OwnerIdentity> watch();

  /// Wipes the identity from synced storage. Use sparingly — this is a
  /// reset operation and the wipe propagates to other devices of the
  /// same account.
  Future<void> delete();

  /// Whether the platform's key-sync subsystem is currently usable.
  ///
  /// Callers use this on first launch to decide between "proceed" and
  /// "block with config message". Cheap to call; result may change at
  /// runtime as the user toggles iCloud Keychain / Google Backup.
  Future<bool> isSyncAvailable();
}
