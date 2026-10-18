import 'package:flutter/foundation.dart';

/// Owner Ed25519 keypair synced across devices of the same human via
/// platform-native key sync (iCloud Keychain / Block Store).
///
/// This is the **only** thing the plugin persists. Higher-level state
/// — paired peers, mesh versions, revocation propagation — lives in
/// the app/relay layers, not here.
///
/// The serialized form is a fixed 64-byte buffer: `ownerPk || ownerSk`.
/// Fixed-width and version-less by design — there is nothing to
/// migrate, so the blob has nothing to negotiate.
@immutable
class OwnerIdentity {
  /// 32-byte Ed25519 public key.
  final Uint8List ownerPk;

  /// 32-byte Ed25519 private key (seed).
  final Uint8List ownerSk;

  OwnerIdentity({
    required Uint8List ownerPk,
    required Uint8List ownerSk,
  })  : ownerPk = Uint8List.fromList(ownerPk),
        ownerSk = Uint8List.fromList(ownerSk) {
    if (this.ownerPk.length != 32) {
      throw ArgumentError.value(
        this.ownerPk.length,
        'ownerPk.length',
        'Ed25519 public key must be exactly 32 bytes',
      );
    }
    if (this.ownerSk.length != 32) {
      throw ArgumentError.value(
        this.ownerSk.length,
        'ownerSk.length',
        'Ed25519 private key (seed) must be exactly 32 bytes',
      );
    }
  }

  /// Canonical serialization: raw `ownerPk || ownerSk`, 64 bytes total.
  Uint8List toBlob() {
    final out = Uint8List(64);
    out.setRange(0, 32, ownerPk);
    out.setRange(32, 64, ownerSk);
    return out;
  }

  /// Throws [FormatException] when [blob] is not exactly 64 bytes.
  static OwnerIdentity fromBlob(Uint8List blob) {
    if (blob.length != 64) {
      throw FormatException(
        'OwnerIdentity: blob must be exactly 64 bytes, got ${blob.length}',
      );
    }
    return OwnerIdentity(
      ownerPk: Uint8List.sublistView(blob, 0, 32),
      ownerSk: Uint8List.sublistView(blob, 32, 64),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! OwnerIdentity) return false;
    return _bytesEqual(ownerPk, other.ownerPk) &&
        _bytesEqual(ownerSk, other.ownerSk);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(ownerPk),
        Object.hashAll(ownerSk),
      );

  @override
  String toString() => 'OwnerIdentity(ownerPk: <32B>, ownerSk: <32B>)';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
