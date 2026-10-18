// Plan/32 — wire parsing of the `compaction` ServerMessage and its
// `session_history` event counterpart (contract: { summary, tokens_before,
// ts optional }).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compaction ServerMessage', () {
    test('parses summary + tokens_before + ts', () {
      final m = ServerMessage.fromJson({
        'type': 'compaction',
        'summary': 'recapped the thread',
        'tokens_before': 12345,
        'ts': 1700000000000,
      });
      final c = m as Compaction;
      expect(c.summary, 'recapped the thread');
      expect(c.tokensBefore, 12345);
      expect(c.ts, 1700000000000);
    });

    test('ts is optional; tokens_before may be absent', () {
      final c = ServerMessage.fromJson({
        'type': 'compaction',
        'summary': 'done',
      }) as Compaction;
      expect(c.summary, 'done');
      expect(c.tokensBefore, isNull);
      expect(c.ts, isNull);
    });
  });

  group('compaction session_history event', () {
    test('parses into CompactionEvt', () {
      final e = SessionHistoryEvent.fromJson({
        'type': 'compaction',
        'ts': 42,
        'summary': 'compacted earlier',
        'tokens_before': 5000,
      });
      final c = e as CompactionEvt;
      expect(c.ts, 42);
      expect(c.summary, 'compacted earlier');
      expect(c.tokensBefore, 5000);
    });

    test('a history batch mixing compaction with other events parses', () {
      final h = ServerMessage.fromJson({
        'type': 'session_history',
        'in_reply_to': 'sync1',
        'session_started_at': 0,
        'eos': true,
        'events': [
          {'type': 'user_input', 'ts': 1, 'id': 'u1', 'text': 'hi'},
          {'type': 'compaction', 'ts': 2, 'summary': 's', 'tokens_before': 9},
        ],
      }) as SessionHistory;
      expect(h.events, hasLength(2));
      expect(h.events[1], isA<CompactionEvt>());
    });
  });
}
