import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Telemetry in Cockpit",
  "description": "Query grouped process errors, structured logs and surrounding output instead of reading entire terminal histories."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["cockpit", "telemetry", "cli"]} />;
}
