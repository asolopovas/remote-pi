import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/chat/quick_actions/widgets/model_picker_sheet.dart';

const peer = 'owner';
const model = WireModel(
  id: 'actual',
  name: 'Actual',
  provider: 'host',
  reasoning: false,
  contextWindow: 1000,
);

class _Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [];
  @override
  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async => [];
  @override
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {}
}

class _Transport implements PeerTransport, IScopedPeerTransport, IControlLink {
  final frames = StreamController<ScopedPeerPayload>();
  final controls = StreamController<ControlInbound>.broadcast();
  late final iterator = StreamIterator(frames.stream);
  final sent = <Map<String, dynamic>>[];
  Future<void> Function()? sending;
  @override
  Future<void> send(Uint8List bytes) {
    sent.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    return sending?.call() ?? Future.value();
  }

  @override
  Future<ScopedPeerPayload> receiveScoped() async {
    if (!await iterator.moveNext()) throw StateError('closed');
    return iterator.current;
  }

  @override
  Future<Uint8List> receive() async => (await receiveScoped()).bytes;
  @override
  Stream<ControlInbound> get controlFrames => controls.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    unawaited(frames.close());
    unawaited(controls.close());
  }

  void reply(
    Map<String, dynamic> message, {
    String sender = peer,
    String? room = 'main',
  }) {
    frames.add((
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(message))),
      peer: sender,
      room: room,
    ));
  }
}

class _Rig {
  final t = _Transport();
  late final ch = PlainPeerChannel(transport: t);
  late final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _Storage(),
    emitDebounce: Duration.zero,
  );
  late final repo = ActionsRepository(
    cm,
    timeout: const Duration(milliseconds: 100),
  );
  Future<void> start({String owner = peer}) async {
    repo;
    cm.adopt(
      ch,
      PeerRecord(
        remoteEpk: owner,
        roomId: 'main',
        sessionName: 'pi',
        relayUrl: 'ws://localhost',
        pairedAt: 'now',
      ),
    );
    await tick();
  }

  void replyList(int index, {String id = 'actual'}) => t.reply({
    'type': 'models_list',
    'in_reply_to': t.sent[index]['id'],
    'models': [
      {
        'id': id,
        'name': id,
        'provider': 'host',
        'reasoning': false,
        'context_window': 1000,
      },
    ],
  });
  void ok(int index, {String? kind}) => t.reply({
    'type': 'action_ok',
    'in_reply_to': t.sent[index]['id'],
    'action': kind ?? t.sent[index]['type'],
  });
  void dispose() {
    repo.dispose();
    cm.dispose();
  }
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));
final failure = throwsA(isA<ActionFailure>());
void main() {
  Future<QuickActionsViewModel> open(WidgetTester tester, _Rig s) async {
    await tester.runAsync(() => s.start());
    final vm = QuickActionsViewModel(s.repo);
    addTearDown(() {
      vm.dispose();
      s.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModelPickerSheet(context, vm: vm),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    return vm;
  }

  testWidgets(
    'invalid picker gives honest chat re-entry instruction and Close, not Retry',
    (tester) async {
      final s = _Rig();
      final vm = await open(tester, s);
      expect(s.t.sent.single['type'], 'list_models');
      await tester.runAsync(() async {
        for (final incarnation in [1, 2, 1]) {
          s.t.controls.add(
            RoomAnnounced(peer: peer, roomId: 'main', startedAt: incarnation),
          );
          await tick();
        }
        s.replyList(0, id: 'stale');
        await tick();
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Session changed. Return to sessions and reopen this chat.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      expect(find.text('stale'), findsNothing);
      await expectLater(
        vm.loadModels(forceRefresh: true),
        throwsA(
          isA<ActionFailure>().having(
            (error) => error.message,
            'message',
            'Session changed. Return to sessions and reopen this chat.',
          ),
        ),
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a model'), findsNothing);
      // Reopening only the picker still uses the invalidated chat VM.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text('Session changed. Return to sessions and reopen this chat.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      await expectLater(vm.setModel(model), failure);
      expect(s.t.sent.map((m) => m['type']), ['list_models']);
    },
  );
  testWidgets(
    'real picker locked failure inline, access instruction and read-only Retry',
    (tester) async {
      final s = _Rig();
      await open(tester, s);
      s.t.reply({
        'type': 'error',
        'in_reply_to': s.t.sent.single['id'],
        'code': 'invalid_message',
        'message': 'Launcher locked/expired. Unlock launching host.',
      });
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      expect(
        find.text('Launcher locked/expired. Unlock launching host.'),
        findsOneWidget,
      );
      expect(
        find.text('Session info → Check access → Unlock launching host'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(s.t.sent.map((m) => m['type']), ['list_models', 'list_models']);
      s.replyList(1);
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      expect(find.text('actual'), findsOneWidget);
    },
  );
  testWidgets(
    'real picker highlights catalogue and exactly one explicit ModelSet; no replay on retry',
    (tester) async {
      final s = _Rig();
      await open(tester, s);
      s.t.reply({
        'type': 'models_list',
        'in_reply_to': s.t.sent.single['id'],
        'models': [
          {
            'id': 'one',
            'name': 'One',
            'provider': 'host',
            'reasoning': false,
            'context_window': 1000,
          },
          {
            'id': 'two',
            'name': 'Two',
            'provider': 'host',
            'reasoning': false,
            'context_window': 1000,
          },
        ],
        'current': {
          'id': 'one',
          'name': 'One',
          'provider': 'host',
          'reasoning': false,
          'context_window': 1000,
        },
      });
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      await tester.tap(find.text('Two'));
      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(s.t.sent.map((m) => m['type']), ['list_models', 'model_set']);
      expect(s.t.sent.last['provider'], 'host');
      expect(s.t.sent.last['model_id'], 'two');
      s.ok(1);
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      expect(find.text('Choose a model'), findsNothing);
    },
  );
  testWidgets(
    'model mutation failure stays inline; Retry reconciles list only',
    (tester) async {
      final s = _Rig();
      await open(tester, s);
      s.replyList(0);
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      await tester.tap(find.text('actual'));
      await tester.pump();
      s.t.reply({
        'type': 'error',
        'in_reply_to': s.t.sent.last['id'],
        'code': 'invalid_message',
        'message': 'Launcher expired',
      });
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
      expect(find.text('Launcher expired'), findsOneWidget);
      await tester.tap(find.text('actual'), warnIfMissed: false);
      await tester.pump();
      expect(s.t.sent.length, 2);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(s.t.sent.map((m) => m['type']), [
        'list_models',
        'model_set',
        'list_models',
      ]);
      s.replyList(2);
      await tester.runAsync(tick);
      await tester.pumpAndSettle();
    },
  );
  test(
    'URL-safe paired key accepts equivalent authenticated standard-base64 sender',
    () async {
      final s = _Rig();
      await s.start(owner: 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE');
      addTearDown(s.dispose);
      final request = s.repo.listModels();
      await tick();
      s.t.reply({
        'type': 'models_list',
        'in_reply_to': s.t.sent.single['id'],
        'models': [],
      }, sender: 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=');
      expect((await request).models, isEmpty);
    },
  );
  test(
    'production Channel generic locked error settles immediately with authenticated scope',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      final messages = <ServerMessage>[];
      final sub = s.ch.serverMessages.listen(messages.add);
      addTearDown(sub.cancel);
      final request = s.repo.listModels();
      final check = expectLater(
        request,
        throwsA(
          isA<ActionFailure>().having(
            (e) => e.message,
            'message',
            contains('Launcher locked'),
          ),
        ),
      );
      await tick();
      s.t.reply({
        'type': 'error',
        'in_reply_to': s.t.sent.single['id'],
        'code': 'invalid_message',
        'message': 'Launcher locked/expired. Unlock launching host.',
      });
      await check;
      expect(messages.single, isA<ScopedActionError>());
    },
  );
  test(
    'wrong sender, room, null scope, id and false-kind acknowledgments cannot settle list',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      var settled = false;
      final request = s.repo.listModels().then((v) {
        settled = true;
        return v;
      });
      await tick();
      final id = s.t.sent.single['id'];
      for (final scope in [
        (peer, 'other'),
        ('attacker', 'main'),
        (peer, null),
      ]) {
        s.t.reply(
          {
            'type': 'error',
            'in_reply_to': id,
            'code': 'invalid_message',
            'message': 'locked',
          },
          sender: scope.$1,
          room: scope.$2,
        );
      }
      s.t.reply({
        'type': 'models_list',
        'in_reply_to': 'unknown',
        'models': [],
      });
      s.ok(0, kind: 'list_models');
      s.ok(0, kind: 'model_set');
      await tick();
      expect(settled, false);
      s.replyList(0);
      expect((await request).models.single.id, 'actual');
    },
  );
  test('wrong action kind cannot authorize model mutation success', () async {
    final s = _Rig();
    await s.start();
    addTearDown(s.dispose);
    var settled = false;
    final request = s.repo
        .setModel('host', 'actual')
        .then((_) => settled = true);
    await tick();
    s.ok(0, kind: 'future_unknown');
    s.replyList(0);
    s.ok(0, kind: 'session_compact');
    await tick();
    expect(settled, false);
    s.ok(0);
    await request;
  });
  for (final mutation in [false, true]) {
    for (final mode in [
      'stalled',
      'throws',
      'late throw',
      'no reply',
      'stream error',
      'close',
    ]) {
      test(
        '$mode end-to-end ${mutation ? "set" : "list"} bounded, late send errors observed',
        () async {
          final s = _Rig();
          await s.start();
          addTearDown(s.dispose);
          final send = Completer<void>();
          if (mode == 'stalled' || mode == 'late throw') {
            s.t.sending = () => send.future;
          }
          if (mode == 'throws') {
            s.t.sending = () => throw StateError('send failed');
          }
          final request = mutation
              ? s.repo.setModel('host', 'actual')
              : s.repo.listModels();
          final check = expectLater(request, failure);
          await tick();
          if (mode == 'stream error') {
            s.t.frames.addError(StateError('wire failed'));
          }
          if (mode == 'close') await s.t.close();
          await check.timeout(const Duration(seconds: 1));
          if (mode == 'late throw') {
            send.completeError(StateError('late send error'));
            await tick();
          }
          if (mode == 'stalled') {
            send.complete();
            await tick();
          }
          expect(s.t.sent.length, 1);
        },
      );
    }
  }
  test(
    'online channel replacement invalidates pending even with same peer and room',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      final check = expectLater(s.repo.listModels(), failure);
      await tick();
      final other = PlainPeerChannel(transport: _Transport());
      s.cm.adopt(other, s.cm.activePeer!);
      await check;
    },
  );
  test(
    'A-B-A selection invalidates forever before debounced metadata and cannot issue mutation B',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      final vm = QuickActionsViewModel(s.repo);
      addTearDown(vm.dispose);
      final check = expectLater(vm.loadModels(), failure);
      await tick();
      s.cm.switchRoom('B');
      s.cm.switchRoom('main');
      await expectLater(vm.setModel(model), failure);
      s.replyList(0);
      await check;
      expect(s.t.sent.map((m) => m['type']), ['list_models']);
    },
  );
  test(
    'room incarnation restore invalidates outstanding request and VM guard forever',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      s.t.controls.add(
        const RoomAnnounced(peer: peer, roomId: 'main', startedAt: 1),
      );
      await tick();
      final vm = QuickActionsViewModel(s.repo);
      addTearDown(vm.dispose);
      final check = expectLater(vm.loadModels(), failure);
      await tick();
      s.t.controls.add(
        const RoomAnnounced(peer: peer, roomId: 'main', startedAt: 2),
      );
      await tick();
      s.t.controls.add(
        const RoomAnnounced(peer: peer, roomId: 'main', startedAt: 1),
      );
      await tick();
      await check;
      await expectLater(vm.setModel(model), failure);
      expect(s.t.sent.length, 1);
    },
  );
  test(
    'pre-discovery VM and pending catalogue never adopt announced replacement or ABA',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      final vm = QuickActionsViewModel(s.repo);
      addTearDown(vm.dispose);
      final oldScope = s.repo.captureActionScope();
      final pending = expectLater(vm.loadModels(), failure);
      await tick();
      for (final incarnation in [1, 2, 1]) {
        s.t.controls.add(
          RoomAnnounced(peer: peer, roomId: 'main', startedAt: incarnation),
        );
        await tick();
      }
      s.replyList(0, id: 'stale');
      await pending;
      expect(oldScope(), false);
      await expectLater(vm.setModel(model), failure);
      await expectLater(vm.loadModels(forceRefresh: true), failure);
      expect(s.t.sent.map((m) => m['type']), ['list_models']);
      expect(vm.currentModel, isNull);
      final fresh = QuickActionsViewModel(s.repo);
      addTearDown(fresh.dispose);
      final catalogue = fresh.loadModels();
      await tick();
      expect(s.t.sent.last['type'], 'list_models');
      s.replyList(1, id: 'fresh');
      expect((await catalogue).models.single.id, 'fresh');
    },
  );
  test('unknown lease cannot revive after room metadata cleanup', () async {
    final s = _Rig();
    await s.start();
    addTearDown(s.dispose);
    final scope = s.repo.captureActionScope();
    final vm = QuickActionsViewModel(s.repo);
    addTearDown(vm.dispose);
    s.t.controls.add(
      const RoomAnnounced(peer: peer, roomId: 'main', startedAt: 1),
    );
    await tick();
    s.t.controls.add(const RoomEnded(peer: peer, roomId: 'main', sinceTs: 2));
    await tick();
    await s.cm.deleteCachedRoom(peer, 'main');
    // Do not sample the captured guard until metadata is absent again.
    expect(scope(), false);
    await expectLater(vm.setModel(model), failure);
    s.t.controls.add(
      const RoomAnnounced(peer: peer, roomId: 'main', startedAt: 1),
    );
    await tick();
    await expectLater(vm.setModel(model), failure);
    expect(s.t.sent, isEmpty);
    final fresh = QuickActionsViewModel(s.repo);
    addTearDown(fresh.dispose);
    final mutation = fresh.setModel(model);
    await tick();
    s.ok(0);
    await mutation;
    expect(s.t.sent.single['type'], 'model_set');
  });
  test('A catalogue is never cached as B even with same room id', () async {
    final s = _Rig();
    await s.start();
    addTearDown(s.dispose);
    final old = expectLater(s.repo.listModels(), failure);
    await tick();
    final otherTransport = _Transport();
    final other = PlainPeerChannel(transport: otherTransport);
    s.cm.adopt(
      other,
      const PeerRecord(
        remoteEpk: 'other-owner',
        sessionName: 'pi',
        relayUrl: 'ws://localhost',
        pairedAt: 'now',
      ),
    );
    await tick();
    await old;
    final request = s.repo.listModels();
    await tick();
    expect(otherTransport.sent.single['type'], 'list_models');
    otherTransport.reply({
      'type': 'models_list',
      'in_reply_to': otherTransport.sent.single['id'],
      'models': [],
    }, sender: 'other-owner');
    expect((await request).models, isEmpty);
  });
  test('reversed refresh cannot replace freshest catalogue', () async {
    final s = _Rig();
    await s.start();
    addTearDown(s.dispose);
    final old = expectLater(s.repo.listModels(), failure);
    await tick();
    final fresh = s.repo.listModels(forceRefresh: true);
    await tick();
    s.replyList(1, id: 'fresh');
    await fresh;
    s.replyList(0, id: 'old');
    await old;
    expect((await s.repo.listModels()).models.single.id, 'fresh');
  });
  test(
    'model_set plus metadata fences earlier list and current highlight; dispose failure safe',
    () async {
      final s = _Rig();
      await s.start();
      addTearDown(s.dispose);
      final vm = QuickActionsViewModel(s.repo);
      final old = expectLater(vm.loadModels(), failure);
      await tick();
      final mutation = vm.setModel(model);
      await tick();
      s.ok(1);
      await mutation;
      s.replyList(0, id: 'old');
      await old;
      expect(vm.currentModel, model);
      s.t.controls.add(
        const RoomAnnounced(
          peer: peer,
          roomId: 'main',
          startedAt: 1,
          model: 'Actual',
        ),
      );
      await tick();
      expect(vm.currentModel, model);
      final request = expectLater(vm.loadModels(forceRefresh: true), failure);
      await tick();
      vm.dispose();
      s.t.reply({
        'type': 'error',
        'in_reply_to': s.t.sent.last['id'],
        'code': 'invalid_message',
        'message': 'locked',
      });
      await request;
    },
  );
}
