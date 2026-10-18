import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const status = LauncherStatus(
    launcherId: 'launcher',
    epoch: 'epoch',
    configured: true,
    unlocked: false,
    expiresAt: null,
    cooldownUntil: 123,
  );
  const producer = {
    'launcher_id': 'launcher',
    'epoch': 'epoch',
    'configured': true,
    'unlocked': false,
    'expires_at': null,
    'cooldown_until': 123,
  };
  test('frozen launcher request shapes match types.ts', () {
    for (final type in ['project_list', 'launcher_status']) {
      expect(LauncherRequest(type, 'id').toJson(), {'type': type, 'id': 'id'});
    }
    for (final type in ['launcher_lock', 'launcher_shutdown']) {
      expect(LauncherRequest(type, 'id', status: status).toJson(), {
        'type': type,
        'id': 'id',
        'launcher_id': 'launcher',
        'epoch': 'epoch',
      });
    }
    expect(
      LauncherRequest(
        'launcher_unlock',
        'id',
        status: status,
        pin: '123456',
      ).toJson(),
      {
        'type': 'launcher_unlock',
        'id': 'id',
        'launcher_id': 'launcher',
        'epoch': 'epoch',
        'pin': '123456',
      },
    );
    expect(
      LauncherRequest(
        'project_launch',
        'id',
        status: status,
        projectId: 'project',
      ).toJson(),
      {
        'type': 'project_launch',
        'id': 'id',
        'launcher_id': 'launcher',
        'epoch': 'epoch',
        'project_id': 'project',
      },
    );
    expect(
      LauncherRequest(
        'project_launch',
        'id',
        status: status,
        projectId: 'project',
        name: 'Fresh',
      ).toJson()['name'],
      'Fresh',
    );
    expect(
      LauncherRequest(
        'launcher_agent_stop',
        'id',
        status: status,
        agentId: 'agent',
      ).toJson(),
      {
        'type': 'launcher_agent_stop',
        'id': 'id',
        'launcher_id': 'launcher',
        'epoch': 'epoch',
        'agent_id': 'agent',
      },
    );
  });
  test('actual nested producer status and shutdown results', () {
    final result =
        ServerMessage.fromJson({
              'type': 'launcher_status_result',
              'in_reply_to': 'id',
              'status': producer,
            })
            as LauncherStatusResult;
    expect(result.inReplyTo, 'id');
    expect(result.status.launcherId, 'launcher');
    expect(result.status.epoch, 'epoch');
    expect(result.status.expiresAt, null);
    expect(result.status.cooldownUntil, 123);
    expect(result.status.permitsControl, false);
    final shutdown =
        ServerMessage.fromJson({
              'type': 'launcher_shutdown_result',
              'in_reply_to': 'id',
              'status': producer,
              'stopped': false,
            })
            as LauncherStatusResult;
    expect(shutdown.stopped, false);
  });
  test('additive pin_setup enum is optional but strict when present', () {
    LauncherStatus parse(Map<String, dynamic> extra) =>
        (ServerMessage.fromJson({
                  'type': 'launcher_status_result',
                  'in_reply_to': 'id',
                  'status': {...producer, ...extra},
                })
                as LauncherStatusResult)
            .status;
    expect(parse({}).pinSetup, null);
    for (final value in PinSetup.values) {
      expect(parse({'pin_setup': value.name}).pinSetup, value);
    }
    for (final value in [null, true, 1, '', 'AVAILABLE', 'unsupported']) {
      expect(() => parse({'pin_setup': value}), throwsFormatException);
    }
    expect(
      LauncherRequest(
        'launcher_pin_initialize',
        'id',
        status: status,
        pin: '123456',
      ).toJson(),
      {
        'type': 'launcher_pin_initialize',
        'id': 'id',
        'launcher_id': 'launcher',
        'epoch': 'epoch',
        'pin': '123456',
      },
    );
  });
  test('launcher API metadata is optional and accepts updated producer', () {
    LauncherStatus parse(Map<String, dynamic> extra) =>
        (ServerMessage.fromJson({
                  'type': 'launcher_status_result',
                  'in_reply_to': 'id',
                  'status': {...producer, ...extra},
                })
                as LauncherStatusResult)
            .status;
    expect(parse({}).launcherApi, null);
    expect(parse({}).supportsNewLaunch, isFalse);
    expect(parse({'launcher_api': 2}).supportsNewLaunch, isFalse);
    expect(parse({'launcher_api': 3}).supportsNewLaunch, isTrue);
    expect(parse({'launcher_api': 4}).supportsNewLaunch, isTrue);
    expect(parse({'launcher_api': 2}).launcherApi, 2);
    expect(() => parse({'launcher_api': '2'}), throwsA(isA<TypeError>()));
  });
  test('actual producer projects carry full directory allowlist', () {
    final result =
        ServerMessage.fromJson({
              'type': 'project_list_result',
              'in_reply_to': 'id',
              'projects': [
                {
                  'project_id': 'p',
                  'name': 'Project',
                  'cwd': '/project',
                  'allowed_folders': ['/project', '/shared'],
                },
              ],
            })
            as ProjectListResult;
    expect(result.projects.single.projectId, 'p');
    expect(result.projects.single.allowedFolders, ['/project', '/shared']);
  });
  test(
    'missing security fields fail closed instead of optimistic defaults',
    () {
      expect(
        () => ServerMessage.fromJson({
          'type': 'launcher_status_result',
          'in_reply_to': 'id',
          'status': {},
        }),
        throwsA(isA<TypeError>()),
      );
    },
  );
}
