import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Daemon mode",
  "description": "The optional supervisor keeps agents running unattended. Review source CLI invocation, permissions, scheduling costs and recovery before enabling it."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["extension", "daemon", "security"]} />;
}
