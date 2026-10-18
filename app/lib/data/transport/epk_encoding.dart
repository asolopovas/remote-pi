// Single point of truth for the epk wire-format coercion.
//
// History (do NOT re-litigate without re-reading):
//   - QR payload + PairingStorage use base64url (RFC 4648 §5; `-_` chars).
//   - Relay's registry / hello / `peer` envelope field use base64 standard
//     (RFC 4648 §4; `+/` chars, `=` padding).
//   - Plano 06 already fixed envelope routing by normalising at
//     `WsTransport._normalizeToStandard` (see `ws_transport.dart`). The
//     control frames added by plano 12 (subscribe_presence, peer_online,
//     etc) re-broke the symmetry — see plano `fix-presence-epk-encoding`.
//
// Until storage moves to standard (TODO plano-storage-encoding), every
// transport-bound epk goes through [toStandardB64]; every inbound
// relay-reported epk goes through [toAppEpk] so it matches the key
// `PairingStorage` already uses.

import 'dart:convert';


/// Convert an epk (possibly base64url from QR/storage) to base64 standard
/// for wire frames the relay reads. Idempotent — already-standard epks
/// pass through unchanged. Unparseable input returned as-is so we never
/// silently drop a bad-looking peer id.
String toStandardB64(String b64) {
  if (b64.isEmpty) return b64;
  try {
    final pad = (4 - b64.length % 4) % 4;
    final bytes = base64Url.decode(b64 + '=' * pad);
    final out = base64.encode(bytes);
    if (out != b64) {
    }
    return out;
  } catch (_) {
    return b64;
  }
}

/// Convert an epk reported by the relay (standard base64) back to the
/// format the app's stores use internally. Today that's base64url so the
/// key matches `PairingStorage`/`PeerRecord.remoteEpk`. Idempotent.
String toAppEpk(String b64) {
  if (b64.isEmpty) return b64;
  try {
    final pad = (4 - b64.length % 4) % 4;
    final bytes = base64.decode(b64 + '=' * pad);
    final out = base64Url.encode(bytes).replaceAll('=', '');
    // Bare bytes don't always round-trip with padding; strip = to match
    // what QR payloads carry.
    return out;
  } on FormatException {
    // Already url-safe? Try the other direction once for symmetry.
    try {
      final pad = (4 - b64.length % 4) % 4;
      base64Url.decode(b64 + '=' * pad);
      return b64;
    } catch (_) {
      return b64;
    }
  }
}
