# Site development

[Project index](../README.md#project-map) · [Website guide](README.md)

Work from `site/`. Commands and Docker deployment are in [README.md](README.md).

- Next.js App Router, React, strict TypeScript, Tailwind 4; pnpm.
- Server Components by default; use `"use client"` only for actual client state/events.
- Routes live in `src/app/`. This presentation site is not the agent or relay backend.
- Use typed props, existing style tokens and `next/image` where appropriate.
- Run `pnpm lint && pnpm build`; fix errors rather than disabling lint.
- Review legal/operator identity, repository/download links and registry destinations before independent deployment. Do not push images to upstream infrastructure.
- Do not commit secrets, `node_modules/`, `.next/` or export output.

For a task explicitly marked `[ORCH:<id>]`, read the [orchestration instructions](../.orchestration/INSTRUCTIONS.md).
