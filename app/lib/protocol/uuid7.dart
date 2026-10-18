// UUIDv7 — time-ordered (48-bit unix_ts_ms) + random tail.
// Layout: 48-bit unix_ts_ms | ver=7 | 12-bit rand_a | variant=10 | 62-bit rand_b
//
// Used as a globally-unique correlation id for protocol messages
// (pair_request, user_message, etc). Per-device counters collide
// across devices owned by the same human (plan/23 owner-key) — see
// the symptom where Android's `cli_4` would prematurely confirm the
// iPhone's `cli_4` pending bubble via the Pi rebroadcast.

import 'dart:math';
import 'dart:typed_data';

final _rng = Random.secure();

String uuid7() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final bytes = Uint8List(16);

  bytes[0] = (ms >> 40) & 0xff;
  bytes[1] = (ms >> 32) & 0xff;
  bytes[2] = (ms >> 24) & 0xff;
  bytes[3] = (ms >> 16) & 0xff;
  bytes[4] = (ms >> 8) & 0xff;
  bytes[5] = ms & 0xff;

  for (var i = 6; i < 16; i++) {
    bytes[i] = _rng.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
