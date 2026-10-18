import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Cockpit reference",
  "description": "Terminal workspaces, SSH remote hosts, layouts, tasks, notebooks, themes and agent automation. Read the owning guides for exact formats and setup."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["index", "cockpit", "remote", "cli", "layouts", "tasks", "notebooks", "themes", "hooks", "telemetry", "security"]} />;
}
