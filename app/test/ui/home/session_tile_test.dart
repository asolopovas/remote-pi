import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer() => PeerRecord(
  remoteEpk: 'pk',
  sessionName: 'continue',
  relayUrl: 'ws://x',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  for (final dark in [true, false]) {
    testWidgets(
      'duplicate projects and long paths at 2x (${dark ? 'dark' : 'light'})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const path = '/home/user/a-very-long-parent-directory/work/project';
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
                        peer: _peer(),
                        room: RoomInfo(
                          roomId: id,
                          startedAt: 1,
                          cwd: path,
                          name: 'try-now',
                        ),
                        isLive: true,
                        onOpen: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('project'), findsNWidgets(2));
        expect(find.text(path), findsNWidgets(2));
        expect(find.textContaining('try-now · alpha-12'), findsOneWidget);
        expect(find.textContaining('try-now · bravo-12'), findsOneWidget);
        expect(find.textContaining('Online · idle'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'generic unnamed projects retain room identity and reconnecting state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final id in ['room-a', 'room-b'])
                  SessionTile(
                    peer: _peer(),
                    room: RoomInfo(
                      roomId: id,
                      startedAt: 1,
                      cwd: '/tmp/project',
                    ),
                    isLive: false,
                    isReconnecting: true,
                    onOpen: () {},
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('project'), findsNWidgets(2));
      expect(find.text('room-a'), findsOneWidget);
      expect(find.text('room-b'), findsOneWidget);
      expect(find.text('Reconnecting'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  test('project basename handles Unix, Windows, absent and root paths', () {
    expect(sessionProjectName('/home/me/project/'), 'project');
    expect(sessionProjectName(r'C:\Users\me\project'), 'project');
    expect(sessionProjectName(null), isNull);
    expect(sessionProjectName('/'), '/');
  });

  testWidgets('tile identifies project, path, session and observed status', (
    tester,
  ) async {
    final room = RoomInfo(
      roomId: 'room-123456789',
      startedAt: 1,
      cwd: r'C:\Users\me\project',
      name: 'try-now',
      model: 'model-x',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTile(
            peer: _peer(),
            room: room,
            isLive: true,
            isWorking: true,
            onOpen: () {},
          ),
        ),
      ),
    );
    expect(find.text('project'), findsOneWidget);
    expect(find.text(r'C:\Users\me\project'), findsOneWidget);
    expect(find.textContaining('try-now · room-123'), findsOneWidget);
    expect(find.textContaining('Working'), findsOneWidget);
  });

  testWidgets('missing directory still identifies session and offline state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTile(
            peer: _peer(),
            room: const RoomInfo(roomId: 'room-1', startedAt: 1),
            isLive: false,
            onOpen: () {},
          ),
        ),
      ),
    );
    expect(find.text('continue'), findsOneWidget);
    expect(find.text('Working directory unavailable'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
  });
}
