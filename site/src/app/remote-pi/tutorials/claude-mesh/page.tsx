import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Claude in the mesh",
  "description": "Advanced terminal-only agent messaging alongside Pi. Consult the source CLI and agent-network contracts for supported integration."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["extension", "messaging", "protocol"]} />;
}
