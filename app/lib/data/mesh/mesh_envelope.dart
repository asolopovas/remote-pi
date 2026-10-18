import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Wire-form wrapper that travels in the body of `POST /mesh/<hash>`
/// requests and `GET /mesh/<hash>` responses.
///
/// Layout:
/// ```json
/// {
///   "blob": "<base64 canonical-JSON bytes>",
///   "sig":  "<base64 Ed25519 signature>"
/// }
/// ```
///
/// `blob` carries the canonical bytes produced by
/// [MeshBlob.toCanonicalBytes]; never re-encode it — Ed25519
/// verification operates on the exact bytes that were signed.
@immutable
class MeshEnvelope {
  /// Canonical JSON bytes of the [MeshBlob] this envelope wraps.
  final Uint8List blob;

  /// Ed25519 signature over [blob], 64 bytes.
  final Uint8List sig;

  MeshEnvelope({required Uint8List blob, required Uint8List sig})
      : blob = Uint8List.fromList(blob),
        sig = Uint8List.fromList(sig);

  /// JSON shape used on the wire — `{blob, sig}` base64.
  Map<String, Object?> toJson() => {
        'blob': base64.encode(blob),
        'sig': base64.encode(sig),
      };

  /// Parses a JSON map produced by [toJson]. The relay's GET response
  /// adds `version` and `updated_at` fields outside the envelope —
  /// callers should extract those before passing the map here.
  static MeshEnvelope fromJson(Map<String, Object?> json) {
    final blob = json['blob'];
    final sig = json['sig'];
    if (blob is! String || sig is! String) {
      throw const FormatException(
        'MeshEnvelope: blob and sig must be base64 strings',
      );
    }
    return MeshEnvelope(
      blob: base64.decode(blob),
      sig: base64.decode(sig),
    );
  }
}
