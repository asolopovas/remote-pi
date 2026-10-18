# Website

[Project index](../README.md#project-map)

Next.js 16 / React 19 presentation site with Tailwind 4. Maintainer and author of contributions: **Andrius Solopovas**.

## Build and check locally

Use Node 22.19+ and pnpm. Run from this directory:

```sh
pnpm install --frozen-lockfile
pnpm dev                       # localhost:3000
pnpm lint
pnpm exec tsc --noEmit
pnpm build
node --experimental-strip-types --test scripts/*.test.mjs
pnpm start
```

Build and prerender tests must use the same public configuration. There are no GitHub workflows. Browser/native-device acceptance and Docker execution are separate from these local checks.

The [workspace override](pnpm-workspace.yaml) pins only `micromatch@4.0.8>braces` in Next's lint tooling to MIT-licensed `@dieub/braces-depth-guard@3.0.3-pn.3`, a **third-party fork**, not an official braces patch (GHSA-vfj7-8cjw-p6xm). No official patched version was available at review. The exact lockfile integrity is required; never follow its `latest` tag. Its published README's claim that `.3` is unpublished is inconsistent with the registry, so publication claims alone are not provenance evidence. The maintainer approved this exact fork after independent cryptographic provenance verification, published-file/source comparison and regression review. Registry signatures and Sigstore workflow identity were verified; the tarball digest matched its signed subject and all ten published files matched the commit. For future changes, review [npm attestations](https://registry.npmjs.org/-/npm/v1/attestations/@dieub%2fbraces-depth-guard@3.0.3-pn.3) against source commit `305a2e4bfe324bb53c336c1b03387ee1251c926f` and verify signatures/artifact digest before adoption or updates. The [focused regressions](scripts/braces-depth-guard.test.mjs) exercise the real Next→fast-glob chain, hard depth bound and unchanged effective lint rules. This introduces separate maintainer trust; clean audits alone do not establish supply-chain safety. Preserve its MIT license and replace the fork only after upstream remediation and equivalent review/tests.

## Public configuration

| Variable | Accepted value | Unset/invalid behavior |
|---|---|---|
| `NEXT_PUBLIC_REPOSITORY_URL` | Explicit HTTPS `github.com/owner/repository`, without credentials/query/fragment | Source/guide links are disabled; no upstream fallback |
| `NEXT_PUBLIC_SITE_URL` | Optional owned HTTPS origin, without path/credentials/query/fragment | Metadata claims no upstream origin |

For this repository, set `NEXT_PUBLIC_REPOSITORY_URL=https://github.com/asolopovas/remote-pi` before building. These values are public build-time configuration, never a place for secrets. Do not commit local environment files.

The [repository-link helper](src/lib/repository-guides.mjs) owns the guide allowlist and validation; [site URL validation](src/lib/site-url.mjs) owns metadata-origin rules. Rendered guides use GitHub `HEAD` so they follow the configured repository's default branch.

## Integrations

- Product setup is maintained once in the [mobile](../app/README.md), [host extension](../pi-extension/README.md), [relay](../relay/README.md) and [Cockpit](../cockpit/README.md) Markdown guides. Docs/tutorial routes link there rather than carrying duplicate recipes.
- `/download` and `/remote-pi/download` are source-guide indexes, not binary distribution. The [app](src/lib/app-release.ts) and [Cockpit](src/lib/cockpit-release.ts) manifest loaders make no requests and return no artifacts; obsolete feed variables do not re-enable them.
- [Build synchronization](scripts/sync-install-sh.mjs) keeps `/install.sh` and `/cockpit-server.sh` as inert, unsuccessful shell endpoints. It does not copy or redirect to an upstream installer. The reviewed local [extension CLI](../pi-extension/README.md#source-cli) and [Cockpit server installer](../cockpit/install-server.sh) are separate entry points with explicit prerequisites.
- [Download hosting](../rp-s3/README.md) and [release packaging](../cockpit/packaging/README.md) are optional manual distribution infrastructure, not active website feeds.
- [Remote Pi artwork](../branding/README.md) and [Cockpit artwork](../cockpit/assets/branding/) are separate sources. Legal routes retain clearly labeled upstream reference material; configure actual operator terms before hosting an independent service.

## Deploy and maintain

The [Dockerfile](Dockerfile) packages standalone output on port 3000. Public configuration must be supplied at image build time:

```sh
docker build --build-arg NEXT_PUBLIC_REPOSITORY_URL=https://github.com/asolopovas/remote-pi -t remote-pi-site .
docker run --rm -p 127.0.0.1:3000:3000 remote-pi-site
```

Pass an owned `NEXT_PUBLIC_SITE_URL` build argument only when you have one. Environment files, local agent state and private key material are excluded from the [Docker context](.dockerignore). No Docker build/deployment is implied by a successful Next.js build.

The [image publisher](push-docker.sh) requires an explicit destination under the [publisher guards](../SECURITY.md#local-publisher-guards). Use an owned TLS proxy and keep credentials outside Git. Follow [development rules](CLAUDE.md) and the shared [security gates](../SECURITY.md).
