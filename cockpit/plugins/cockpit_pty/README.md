# cockpit_pty

[Project index](../../../README.md#project-map) · [Cockpit guide](../../README.md)

Internal native PTY plugin, consumed through a path dependency by Cockpit. Based on `kyroon_pty` 1.0.6; see [LICENSE](LICENSE) and the [upstream change history](CHANGELOG.md). This renamed package is not published to pub.dev.

## API

The implementation is [lib/cockpit_pty.dart](lib/cockpit_pty.dart), with Unix `forkpty` and Windows ConPTY backends. Windows requires Windows 10 1809+. Mobile remote terminals use Cockpit's SSH/server transport; this plugin does not include a WebSocket server or browser example.

```dart
import 'dart:convert';
import 'dart:io';
import 'package:cockpit_pty/cockpit_pty.dart';

final pty = Pty.start(
  Platform.isWindows ? 'cmd.exe' : '/bin/sh',
  rows: 25,
  columns: 80,
  ackRead: true,
);
final subscription = pty.output.listen((bytes) {
  // Consume/deliver bytes before acknowledging; do not drop hidden-tab output.
  stdout.add(bytes);
  pty.ackRead();
});
pty.write(utf8.encode('echo ready\r'));
pty.resize(30, 100); // rows, columns
// At the owning session's teardown:
pty.kill();
await subscription.cancel();
```

`Pty.start` also accepts `arguments`, `workingDirectory` and `environment`. The **full parent environment is inherited**; `TERM=xterm-256color` and `LANG=en_US.UTF-8` are defaults only when absent, then explicit overrides apply. Do not pass untrusted environment/command configuration.

- `output` combines stdout/stderr as `Stream<Uint8List>`; use a streaming UTF-8 decoder when converting to text because characters can span chunks.
- `exitCode` is platform-specific. Do not assume output has drained solely because the exit future completes.
- With `ackRead: true`, acknowledge consumed chunks or output stalls. Without it, native output is not application-paced.
- `kill()` defaults to SIGTERM on POSIX; Windows uses native Job Object termination rather than Unix signal semantics.
- Session owners must clean up processes, stream subscriptions and terminal controllers. Follow [Cockpit's terminal flow-control rules](../../docs/terminal-output-flow-control.md).

## Maintain

Native implementation/header: `src/`; generated FFI bindings: `lib/src/cockpit_pty_bindings_generated.dart`. Regenerate bindings after header changes, from this directory:

```sh
flutter pub get
dart run ffigen --config ffigen.yaml
```

Run Cockpit's terminal tests/builds from `cockpit/`; native Windows regression instructions are in [test/windows/README.md](test/windows/README.md). Keep the plugin license in source and binary distributions.
