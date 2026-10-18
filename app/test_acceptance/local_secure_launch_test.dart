// Explicit root-gate acceptance (outside default test/ discovery): real Rust
// router, extension launcher and bundled Pi.
// No phone, production pairing, provider request or secure-storage plugin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/agents/agent_repository_impl.dart';
import 'package:app/data/agents/fresh_launcher_repository_impl.dart';
import 'package:app/data/agents/session_control_repository_impl.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends PairingStorage {
  _Storage(this.peer);
  final PeerRecord peer;
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<PeerRecord?> loadPeer(String key) async =>
      key == peer.remoteEpk ? peer : null;
  @override
  Future<List<PersistedRoom>> loadRooms(String key) async => [];
  @override
  Future<void> saveRooms(String key, List<PersistedRoom> rooms) async {}
  @override
  Future<void> savePeer(PeerRecord value) async {}
}

class _Preferences extends Preferences {
  @override
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {}
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Real relay discovery deadline');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  for (final mode in ['valid', 'missing', 'invalid']) {
    test(
      'real relay → protected Start → $mode runtime → exact Stop',
      () async {
        final host = await Process.start('node', [
          'test/support/local-launch-host.mjs',
          mode,
        ], workingDirectory: '../pi-extension');
        final stderr = StringBuffer();
        final errors = host.stderr.transform(utf8.decoder).listen(stderr.write);
        final lines = StreamIterator(
          host.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        addTearDown(() async {
          await host.stdin.close();
          try {
            expect(
              await host.exitCode.timeout(const Duration(seconds: 12)),
              0,
              reason: stderr.toString(),
            );
          } on TimeoutException {
            host.kill(ProcessSignal.sigkill);
            await host.exitCode;
            fail('Fixture cleanup deadline: $stderr');
          } finally {
            await lines.cancel();
            await errors.cancel();
          }
        });
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
          reason: stderr.toString(),
        );
        final config = jsonDecode(lines.current) as Map<String, dynamic>;
        final key = await Ed25519().newKeyPairFromSeed(
          base64.decode(config['seed'] as String),
        );
        final peer = PeerRecord(
          remoteEpk: config['host'] as String,
          relayUrl: config['url'] as String,
          roomId: 'fixture-root',
          sessionName: 'Synthetic local host',
          pairedAt: '2026-01-01',
        );
        final storage = _Storage(peer);
        final conn = ConnectionManager(
          storage: storage,
          emitDebounce: Duration.zero,
          factory: (_, _) async => PlainPeerChannel(
            transport: await WsTransport.connect(
              relayUrl: peer.relayUrl,
              peerPubkey: peer.remoteEpk,
              ed25519Key: key,
            ),
          ),
        );
        final prefs = _Preferences();
        final fresh = FreshLauncherRepositoryImpl(conn, storage);
        final agents = AgentRepositoryImpl(
          conn,
          storage,
          AgentMutationJournal(),
          prefs,
        );
        final controls = SessionControlRepositoryImpl(conn);
        addTearDown(() async {
          controls.dispose();
          agents.dispose();
          fresh.dispose();
          prefs.dispose();
          await conn.disconnect();
          conn.dispose();
          storage.dispose();
        });
        await conn.connectTo(peer);
        conn.subscribeToPeers([peer.remoteEpk]);
        await _until(() => conn.isRoomLive(peer.remoteEpk, 'fixture-root'));
        final endpoint = await fresh.resolve(
          peer.remoteEpk,
          preferredRoom: 'fixture-root',
        );
        expect(endpoint.room, 'fixture-root');
        await agents.bind(
          endpoint.peer,
          endpoint.room,
          isCurrent: () {
            fresh.checkCurrent();
            return true;
          },
        );
        await agents.status();
        expect(agents.launcherStatus!.unlocked, isFalse);
        // A real, correlated host denial must surface as failure, not timeout.
        final watch = <ServerMessage>[];
        final sub = conn.channel!.serverMessages.listen(watch.add);
        addTearDown(sub.cancel);
        await expectLater(
          agents.unlock('111111'),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.outcomeUnknown,
              'correlated denial',
              isFalse,
            ),
          ),
        );
        expect(watch.whereType<ErrorMessage>(), isNotEmpty);
        await agents.status();
        final wait =
            agents.launcherStatus!.cooldownUntil -
            DateTime.now().millisecondsSinceEpoch;
        if (wait > 0) {
          await Future<void>.delayed(Duration(milliseconds: wait + 25));
        }
        await agents.unlock('654321');
        await agents.list();
        expect(agents.projects, hasLength(1));
        if (mode != 'valid') {
          await expectLater(
            agents.launch(agents.projects.single.projectId, 'Local fixture'),
            throwsA(
              isA<AgentFailure>()
                  .having(
                    (e) => e.message,
                    'actionable runtime error',
                    'Prepare the private Pi 1.3.0 managed runtime locally with scripts/prepare-managed-runtime.mjs; inspect its ownership, integrity and bounded closure',
                  )
                  .having(
                    (e) => e.outcomeUnknown,
                    'correlated failure',
                    isFalse,
                  ),
            ),
          );
          expect(conn.roomsFor(peer.remoteEpk).map((r) => r.roomId), [
            'fixture-root',
          ]);
          expect(conn.activeRoomId, 'fixture-root');
          return;
        }
        final agent = await agents.launch(
          agents.projects.single.projectId,
          'Local fixture',
        );
        // Running means the real bundled Pi passed the get_state/model gate.
        expect(agent.state, 'running', reason: agent.error);
        await agents.openAgent(
          agent,
          beforeHandoff: (p, _) => fresh.consumeHandoff(p, agent),
        );
        expect(conn.activeRoomId, agent.roomId);
        expect(conn.isRoomLive(peer.remoteEpk, agent.roomId), isTrue);
        final capability = await controls.inspect(peer.remoteEpk, agent.roomId);
        expect(capability.canStop, isTrue);
        expect(capability.launchingHost!.roomId, 'fixture-root');
        expect(capability.launchingHost!.launcherId, endpoint.launcherId);
        expect(await controls.stop(capability), SessionStopOutcome.stopped);
        // Client capability consumption only; this is not server replay proof.
        await expectLater(
          controls.stop(capability),
          throwsA(isA<SessionControlFailure>()),
        );
        await _until(() => !conn.isRoomLive(peer.remoteEpk, agent.roomId));
        expect(conn.isRoomLive(peer.remoteEpk, 'fixture-root'), isTrue);
      },
      timeout: const Timeout(Duration(seconds: 100)),
    );
  }
}
