import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Build Cockpit from source",
  "description": "Binary downloads are disabled for this independent repository. Build the desktop app and matching SSH server from the canonical source guides."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["cockpit", "remote", "security"]} />;
}
