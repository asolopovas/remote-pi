# Security and publication

[Project index](README.md#project-map) · [Protocol trust model](PROTOCOL.md#modelo-de-proteção-trust-model)

## Report a vulnerability

Contact [Andrius Solopovas](https://github.com/asolopovas) privately. Use GitHub private vulnerability reporting if it is enabled; otherwise arrange a private channel before sharing exploit details. Never put credentials, private keys or sensitive transcripts in public issues.

## Secrets and local state

Keep provider credentials, PIN verifiers, pairing identities, database passwords, SSH/signing keys and deployment tokens outside Git. Runtime locations and ownership are documented in the [extension configuration](pi-extension/README.md#relay-and-local-configuration), [launcher contract](pi-extension/docs/secure-launcher.md#initial-pin-from-phone--local-operator-setup) and [Cockpit package map](cockpit/README.md#package-map). Follow [.gitignore](.gitignore); an ignore rule does not remove an already tracked secret.

The SSH keys and pairing tokens in test fixtures are synthetic. Never authorize their public keys on a real system. [.gitleaksignore](.gitleaksignore) exempts only exact reviewed historical fingerprints, not whole files or future changes.

If a real secret is committed, revoke/rotate it first, stop publication and notify the maintainer privately. Deleting it from the current tree is insufficient. History removal requires explicit authorization; never rewrite history or discard local work automatically.

## Before publication or deployment

Run from the repository root with Gitleaks installed:

```sh
gitleaks git . --log-opts=HEAD --redact=100
python3 scripts/check-docs.py
```

Review the exact branch being published, all changed tracked files, Git ignore behavior and build outputs. Do not mirror every local ref or push local configuration. History can contain retired non-secret configuration even when the current tree excludes it.

Audit locked dependencies from their own directories:

```sh
(cd site && pnpm audit)
(cd pi-extension && pnpm audit)
(cd relay && cargo audit)
(cd rp-s3 && cargo audit)
(cd cockpit/cli && cargo audit)
```

A clean credential scan is not a dependency audit, and a clean dependency audit is not proof of secure deployment. Review reachability, native/mobile plugins, bundled JavaScript and operating-system dependencies separately. Apply supported patches, rerun project tests/builds, and document residual risks rather than suppressing advisories or overriding incompatible APIs blindly.

The [host extension is source-only](pi-extension/README.md#build-and-install-this-source): its workspace-level security override is not inherited by npm consumers, so registry publication/global npm installation is unsupported. A zero-advisory source audit is not evidence that a packed npm dependency graph is safe.

There are no GitHub workflows or automatic releases. Run all audits/tests locally; Git tags do not authorize a build, upload or deployment. GitHub Actions should remain disabled on the independent repository.

Before using installers, updates or manual release procedures, configure an explicitly owned package/repository, HTTPS upload/feed destinations and matching signing keys. Never send publication credentials to an upstream default, accept an unrelated publisher's update authority, bypass certificate validation or disable signature/checksum verification. See [release packaging](cockpit/packaging/README.md), [website deployment](site/README.md), and [download-server operations](rp-s3/README.md#routes-and-operation).

## Local publisher guards

These scripts fail before activity unless an explicit destination is supplied. Syntax validation does not establish ownership; verify the publisher account and destination authorization yourself.

| Entry point | Required destination |
|---|---|
| [Relay image](relay/push-docker.sh), [website image](site/push-docker.sh), [download-server image](rp-s3/push-docker.sh) | `DOCKER_IMAGE=owned-namespace/repository` or `registry[:port]/repository`, without tag/digest |
| [Cockpit binary installer](cockpit/install-server.sh) | `COCKPIT_REPO=owner/repository` after owned compatible releases exist |
| [Extension registry bootstrap](pi-extension/install.sh) | `REMOTE_PI_PACKAGE` explicitly selects a package; it is not the supported source-only installation of this checkout |

Run local destination/disable-default regressions from the repository root:

```sh
python3 scripts/test-installers.py
python3 scripts/test-docker-publishers.py
```

## Runtime limits

Read the [protocol trust model](PROTOCOL.md#modelo-de-proteção-trust-model), [launcher sandbox limits](pi-extension/docs/secure-launcher.md#sandbox-and-parentchild-transport-scope), and [Cockpit SSH protocol](cockpit/docs/remote-protocol.md) before exposing a service. Start only trusted projects, restrict network access, keep TLS termination current and protect backups. Never relax pairing, filesystem or credential checks to get a launch/build working.
