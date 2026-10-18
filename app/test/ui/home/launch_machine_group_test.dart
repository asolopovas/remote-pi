import 'dart:convert';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../agents/session_control_repository_test.dart' as f;

class Storage extends f.Storage {
  Storage(this.peers);
  final List<PeerRecord> peers;
  @override
  Future<List<PeerRecord>> listPeers() async => peers;
}

void main() {
  for (final distinct in [false, true]) {
    test(
      'two same-label same-cwd sessions: ${distinct ? "two machines" : "one machine"}; Home counts stay two',
      () async {
        final bytes = List.filled(32, 255);
        final first = PeerRecord(
          remoteEpk: base64.encode(bytes),
          sessionName: 'same',
          relayUrl: 'https://relay.invalid',
          pairedAt: '2026-01-01',
        );
        final second = PeerRecord(
          sessionName: 'same',
          pairedAt: '2026-01-01',
          remoteEpk: distinct
              ? base64.encode(List.filled(32, 2))
              : base64Url.encode(bytes).replaceAll('=', ''),
          relayUrl: 'https://stale-qr.invalid',
        );
        final storage = Storage([first, second]);
        final ch = f.Channel();
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        await conn.connectTo(first);
        final vm = HomeViewModel(storage, Preferences(), conn);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        for (final (peer, room) in [(first, 'r1'), (second, 'r2')]) {
          ch.controls.add(
            RoomAnnounced(
              peer: peer.remoteEpk,
              roomId: room,
              startedAt: 1,
              cwd: '/same',
              name: 'same',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(vm.launchMachines, hasLength(distinct ? 2 : 1));
        // Duplicate raw encodings in storage may duplicate ordinary rows, but a
        // single stored identity with two rooms always retains both Home sessions.
        expect(vm.launchMachines.expand((g) => g), hasLength(2));
        if (distinct) expect(vm.counts.online, 2);
        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );
  }
}
