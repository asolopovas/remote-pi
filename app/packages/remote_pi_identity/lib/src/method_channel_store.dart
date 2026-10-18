import 'dart:async';

import 'package:flutter/services.dart';

import 'owner_identity.dart';
import 'owner_identity_store.dart';

/// Production [OwnerIdentityStore] that proxies to the native iOS /
/// Android implementations via Flutter MethodChannel + EventChannel.
///
/// Method channel: `remote_pi_identity`
/// Event channel:  `remote_pi_identity/events`
///
/// Native side returns raw bytes (`Uint8List`) for the blob; the Dart
/// side does (de)serialization via [OwnerIdentity.toBlob] / [fromBlob],
/// so the native code stays dumb (it only knows "here's a blob, store
/// it / read it / watch it").
class MethodChannelOwnerIdentityStore implements OwnerIdentityStore {
  static const _methodChannel = MethodChannel('remote_pi_identity');
  static const _eventChannel = EventChannel('remote_pi_identity/events');

  Stream<OwnerIdentity>? _watch;

  @override
  Future<OwnerIdentity?> load() async {
    try {
      final raw = await _methodChannel.invokeMethod<Uint8List>('load');
      if (raw == null) return null;
      return OwnerIdentity.fromBlob(raw);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    try {
      await _methodChannel.invokeMethod<void>('save', {
        'blob': identity.toBlob(),
      });
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Stream<OwnerIdentity> watch() {
    return _watch ??= _eventChannel
        .receiveBroadcastStream()
        .map<OwnerIdentity>((event) {
      if (event is! Uint8List) {
        throw IdentityStoreError.platform(
          'invalid_event',
          'Expected Uint8List blob from event channel, got ${event.runtimeType}',
        );
      }
      return OwnerIdentity.fromBlob(event);
    });
  }

  @override
  Future<void> delete() async {
    try {
      await _methodChannel.invokeMethod<void>('delete');
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<bool> isSyncAvailable() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isSyncAvailable');
      return result ?? false;
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// Translates the platform's error code/message into the typed
  /// [IdentityStoreError] hierarchy. Native code raises
  /// `sync_unavailable` when the user's iCloud Keychain / Google Backup
  /// is off; anything else surfaces as a [PlatformFailure].
  IdentityStoreError _mapPlatformException(PlatformException e) {
    if (e.code == 'sync_unavailable') {
      return IdentityStoreError.syncUnavailable(e.message ?? 'sync_unavailable');
    }
    return IdentityStoreError.platform(e.code, e.message ?? '');
  }
}
