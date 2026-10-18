import 'dart:convert';
import 'dart:io';

import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/core/session_label.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'synthetic',
  sessionName: 'device',
  relayUrl: 'ws://synthetic',
  pairedAt: '2026-01-01',
);
RoomDisplay fixtureDisplay(String caseName) {
  final rows =
      jsonDecode(
            File(
              'test/protocol/fixtures/81-display-serialization.json',
            ).readAsStringSync(),
          )
          as List;
  final frame =
      (rows.singleWhere((r) => r['case'] == caseName) as Map)['frame'] as Map;
  return RoomDisplay.tryFromJson((frame['meta'] as Map)['display'])!;
}

void main() {
  test(
    'shared precedence: verified desktop, saved alias, reset, invalidation, cold fallbacks',
    () {
      final room = RoomInfo(
        roomId: 'r1',
        startedAt: 1,
        name: 'routing-agent',
        cwd: '/synthetic/duplicate',
        display: fixtureDisplay('rename'),
      );
      expect(sessionDisplayName(room, peer), 'Pi · system');
      expect(
        sessionDisplayName(room.copyWith(localName: 'Mobile <plain>'), peer),
        'Pi · system',
      );
      expect(
        sessionDisplayName(room.copyWith(localName: '  '), peer),
        'Pi · system',
      );
      expect(
        sessionDisplayName(
          room.copyWith(display: fixtureDisplay('reset tombstone')),
          peer,
        ),
        'duplicate',
      );
      final aliased = room.copyWith(localName: 'Saved alias');
      expect(
        sessionDisplayName(
          aliased.copyWith(display: fixtureDisplay('reset tombstone')),
          peer,
        ),
        'Saved alias',
      );
      expect(aliased.localName, 'Saved alias');
      final offline = room.copyWith(display: null);
      expect(sessionDisplayName(offline, peer), 'duplicate');
      expect(
        sessionDisplayName(offline.copyWith(localName: 'Saved alias'), peer),
        'Saved alias',
      );
      expect(
        sessionDisplayName(
          const RoomInfo(roomId: 'r1', startedAt: 1, name: 'routing'),
          peer,
        ),
        'routing',
      );
      expect(
        sessionDisplayName(null, peer.copyWith(nickname: 'Device nickname')),
        'Device nickname',
      );
      expect(sessionDisplayName(null, peer), 'device');
      expect(
        sessionDisplayName(const RoomInfo(roomId: 'r1', startedAt: 1), null),
        'r1',
      );
      expect(sessionDisplayName(null, null), 'Session');
      expect(room.name, 'routing-agent');
      expect(room.roomId, 'r1');
    },
  );
  for (final dark in [true, false]) {
    testWidgets(
      'plain desktop labels preserve duplicate room context at 320px/2x ${dark ? 'dark' : 'light'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final desktop = RoomDisplay.tryFromJson({
          ...fixtureDisplay('rename').toJson(),
          'name': '<plain> **not markdown** ${'long label ' * 8}',
        })!;
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: ListView(
                  children: [
                    for (final id in ['alpha-123456', 'bravo-123456'])
                      SessionTile(
                        peer: peer,
                        room: RoomInfo(
                          roomId: id,
                          startedAt: 1,
                          name: 'routing',
                          cwd: '/synthetic/duplicate',
                          display: desktop,
                        ),
                        isLive: true,
                        onOpen: () {},
                      ),
                    SessionTile(
                      peer: peer,
                      room: const RoomInfo(
                        roomId: 'offline',
                        startedAt: 1,
                        cwd: '/synthetic/duplicate',
                      ),
                      isLive: false,
                      onOpen: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text(desktop.name!), findsNWidgets(2));
        expect(
          tester.getSemantics(find.text(desktop.name!).first).label,
          contains(desktop.name!),
        );
        expect(find.textContaining('routing · alpha-12'), findsOneWidget);
        expect(find.textContaining('routing · bravo-12'), findsOneWidget);
        expect(find.text('/synthetic/duplicate'), findsNWidgets(3));
        expect(find.textContaining('Offline'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text(desktop.name!).first).overflow,
          TextOverflow.ellipsis,
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }
  testWidgets(
    'accepted producer rename is Home title and avatar, not routing identity',
    (tester) async {
      final room = RoomInfo(
        roomId: 'exact-room',
        startedAt: 1,
        name: 'routing-agent',
        cwd: '/synthetic/duplicate',
        display: fixtureDisplay('rename'),
      );
      expect(HomeItem(peer: peer, room: room).displayName, 'Pi · system');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionTile(
              peer: peer,
              room: room,
              isLive: true,
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.text('Pi · system'), findsOneWidget);
      expect(find.text('P'), findsOneWidget);
      expect(find.textContaining('routing-agent · exact-ro'), findsOneWidget);
    },
  );
}
