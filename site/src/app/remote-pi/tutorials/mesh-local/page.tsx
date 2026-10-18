import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Local mesh",
  "description": "Agents on the same machine discover each other and exchange messages through the local broker. The agent-network guide owns addressing and reply handling."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["extension", "messaging", "protocol"]} />;
}
