import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/session_status_indicator.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/home/widgets/session_tile.dart';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() => _ctrl.close();
}

/// No peer paired → ChatViewModel stays with activePeer == null (the case we
/// want: the subtitle must come from initialDevice, not the PeerRecord).
class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
  @override
  Future<PeerRecord?> loadPeer(String epk) async => null;
}

class _FakeSecureStorage implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StatusVM extends ChatViewModel {
  _StatusVM(super.read, super.sync, super.conn, super.prefs, super.storage);
  bool working = true;
  bool resolved = false;
  bool online = true;
  @override
  bool get isWorking => working;
  @override
  bool get connectionResolved => resolved;
  @override
  bool get isRoomLive => online;
}

// Production widgets with inert transport/speech, not real paired route data.
void main() {
  late Directory dir;
  const capturePhase = String.fromEnvironment('STATUS_CAPTURE');
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_status_design_');
    await LocalBoxes.initForTest(dir.path);
    if (capturePhase.isNotEmpty) {
      const sansFont = String.fromEnvironment('STATUS_SANS_FONT');
      await (FontLoader('Roboto')..addFont(
            File(
              sansFont,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
      for (final (family, asset) in [
        (kMonoFamily, 'assets/fonts/fira_mono/FiraMonoNerdFont-Regular.otf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        (
          'packages/lucide_icons_flutter/Lucide',
          'packages/lucide_icons_flutter/assets/lucide.ttf',
        ),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
      }
    }
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });
  for (final size in [
    const Size(360, 800),
    const Size(412, 915),
    const Size(768, 1024),
  ]) {
    for (final dark in [true, false]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'production status surfaces ${size.width} ${dark ? 'dark' : 'light'} ${scale}x',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final conn = ConnectionManager(
              factory: (_, _) async => _FakeChannel(),
              storage: _FakeStorage(),
            );
            final boxes = LocalBoxes();
            final sync = SyncService(conn, boxes);
            final prefs = Preferences(_FakeSecureStorage());
            final actions = ActionsRepository(conn);
            final vm = _StatusVM(
              SessionReadRepository(boxes),
              sync,
              conn,
              prefs,
              _FakeStorage(),
            );
            final voice = VoiceInputViewModel(_FakeSpeech());
            final attach = AttachmentViewModel(_FakePicker(), actions);
            final sel = SessionSelection();
            final capture = GlobalKey();
            Future<void> show(Widget child) => tester.pumpWidget(
              MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                home: MultiProvider(
                  providers: [
                    ChangeNotifierProvider<ChatViewModel>.value(value: vm),
                    ChangeNotifierProvider<VoiceInputViewModel>.value(
                      value: voice,
                    ),
                    ChangeNotifierProvider<AttachmentViewModel>.value(
                      value: attach,
                    ),
                    ChangeNotifierProvider<Preferences>.value(value: prefs),
                    ChangeNotifierProvider<SessionSelection>.value(value: sel),
                  ],
                  child: Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: RepaintBoundary(key: capture, child: child),
                    ),
                  ),
                ),
              ),
            );
            Future<void> snapshot(String surface) async {
              if (capturePhase.isEmpty) return;
              await tester.pump(const Duration(milliseconds: 180));
              final boundary =
                  capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage();
                final png = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final out = Directory('build/93-dictation-status/$capturePhase')
                  ..createSync(recursive: true);
                File(
                  '${out.path}/$surface-${size.width.toInt()}-${dark ? 'dark' : 'light'}-${scale}x.png',
                ).writeAsBytesSync(png!.buffer.asUint8List());
                image.dispose();
              });
            }

            await show(
              const ChatPage(
                initialTitle: 'Long project name with session context',
                initialDevice: 'Workstation with a long device name',
                initialOnline: true,
              ),
            );
            await tester.pump();
            await snapshot('chat');
            expect(tester.takeException(), isNull);
            expect(find.text('working…'), findsOneWidget);
            vm.resolved = true;
            for (final working in [true, false]) {
              for (final reconnecting in [true, false]) {
                for (final online in [true, false]) {
                  vm.working = working;
                  vm.online = online;
                  vm.emit(const ChatConnecting());
                  vm.emit(
                    ChatReady(messages: const [], isOffline: reconnecting),
                  );
                  await tester.pump();
                  final status = SessionStatus.resolve(
                    isWorking: working,
                    isReconnecting: reconnecting,
                    isOnline: online,
                  );
                  final label = switch (status) {
                    SessionStatus.working => 'working…',
                    SessionStatus.reconnecting => 'reconnecting…',
                    _ => status.label.toLowerCase(),
                  };
                  expect(find.text(label), findsOneWidget);
                  expect(
                    tester
                        .widget<SessionStatusIndicator>(
                          find.byType(SessionStatusIndicator),
                        )
                        .status,
                    status,
                  );
                  expect(tester.takeException(), isNull);
                  if (!working && reconnecting && !online) {
                    await snapshot('chat-reconnecting');
                  }
                }
              }
            }
            await show(
              Scaffold(
                body: ListView(
                  children: [
                    for (final status in [
                      'Working',
                      'Reconnecting',
                      'Online',
                      'Offline',
                    ])
                      SessionTile(
                        peer: PeerRecord(
                          remoteEpk: 'synthetic',
                          sessionName: 'Long session name',
                          relayUrl: 'ws://invalid',
                          pairedAt: '2026-01-01',
                        ),
                        room: const RoomInfo(
                          roomId: 'session-123456',
                          startedAt: 1,
                          cwd: '/home/user/a-long-parent-directory/project',
                          name: 'long-session-name',
                          model: 'model-with-context',
                        ),
                        isLive: status != 'Offline',
                        isWorking: status == 'Working',
                        isReconnecting: status == 'Reconnecting',
                        isSelected: status == 'Working',
                        onOpen: () {},
                      ),
                  ],
                ),
              ),
            );
            await tester.pump();
            await snapshot('sessions');
            expect(tester.takeException(), isNull);
            for (final label in [
              'Working',
              'Reconnecting',
              'Online · idle',
              'Offline',
            ]) {
              expect(find.text(label), findsOneWidget);
              final paragraph = tester.renderObject<RenderParagraph>(
                find.text(label),
              );
              expect(paragraph.didExceedMaxLines, false);
            }
            await tester.pumpWidget(const SizedBox());
            vm.dispose();
            attach.dispose();
            voice.dispose();
            actions.dispose();
            sync.dispose();
            sel.dispose();
            conn.dispose();
          },
        );
      }
    }
  }
}
