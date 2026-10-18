import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "An agent team in Cockpit",
  "description": "Run orchestrator and worker agents in separate terminal tabs and folders. Use the CLI automation reference for targeting and coordination."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["cockpit", "cli", "hooks", "security"]} />;
}
