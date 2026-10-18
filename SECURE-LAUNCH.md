# PIN-protected phone launcher

[Project index](README.md#project-map) · [Mobile guide](app/README.md) · [Host launcher contract](pi-extension/docs/secure-launcher.md)

The mobile **+** action starts a fresh sandboxed agent in a locally registered project. It does not send an initial prompt/model turn. This guide owns the phone workflow; configuration and wire details remain in the host contract.

## Host setup

Build the [extension](pi-extension/README.md#build-and-install-this-source) and [mobile client](app/README.md#build-and-run). Before using Start, follow the host contract's [local project/PIN setup](pi-extension/docs/secure-launcher.md#initial-pin-from-phone--local-operator-setup) and [API3 runtime prerequisites/preparation](pi-extension/docs/secure-launcher.md#managed-runtime-packaging-api3). Do not substitute the extension SDK for the managed child runtime.

Use a [trusted relay](relay/README.md#self-host-with-docker) on both endpoints. Register only directories you authorize. Never put a PIN in arguments, environment variables or chat; existing/corrupt/unsafe verifiers require local recovery, not a remote reset.

## Phone workflow

1. Tap **+** and select a paired host when more than one exists.
2. Create the first 6–12 digit PIN on a supported host, or unlock an existing verifier. Existing PINs cannot be replaced remotely.
3. Select a registered project and confirm Start. Wait for actual readiness/discovery before treating it as an online agent.
4. Use **Check status** for uncertain results. A timeout does not prove no child was created; a new Start requires explicit duplicate-risk confirmation, never automatic replay.
5. Use a confirmed Stop control for the exact owned agent. A requested acknowledgement is not proof of exit.

**Check access / Unlock launching host** recovers authority through the actual parent. Older metadata requires explicit selection, never guessing. See [managed session access](pi-extension/docs/session-control.md#managed-session-access-and-launching-host) for authority, expiry and the recovery sequence.

**Lock access** revokes control but leaves admitted work running. Launcher shutdown affects only that Owner's managed children; normal host close/session replacement/reload terminates the host's children. Do not reload an active host to update it.

Offline **Remove from list** removes local session metadata only—it is not Stop, pairing removal or host history deletion.

## Limits and maintenance

Start only trusted projects on trusted infrastructure. Review [sandbox/credential/network limits](pi-extension/docs/secure-launcher.md#sandbox-and-parentchild-transport-scope), [exact-session stopping](pi-extension/docs/session-control.md) and the [protocol trust model](PROTOCOL.md#modelo-de-proteção-trust-model) before enabling access.

Update immutable runtimes only at idle-safe boundaries; never delete a release a session may still use. Automated fixtures do not establish real-phone, microphone, deployed-host or provider acceptance. Validate those separately after deploying owned builds.
