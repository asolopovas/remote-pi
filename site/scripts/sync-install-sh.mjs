// The independent website does not deliver bootstrap installers. Keep legacy
// endpoints inert in local and standalone/Docker builds alike. Do not copy the
// sibling installer: that would re-enable registry/service installation.
import { chmodSync, writeFileSync } from "node:fs";

const disabled = `#!/bin/sh
# Remote Pi derives from Jacob Moura / Flutterando's MIT-licensed project.
printf '%s\\n' 'Installer disabled: this repository is source-only. Open the website documentation and configure NEXT_PUBLIC_REPOSITORY_URL to access the owned source guides.' >&2
exit 1
`;

for (const name of ["install.sh", "cockpit-server.sh"]) {
  const path = new URL(`../public/${name}`, import.meta.url);
  writeFileSync(path, disabled);
  chmodSync(path, 0o644);
}
console.log("[sync-install-sh] legacy installer endpoints disabled (source-only)");
