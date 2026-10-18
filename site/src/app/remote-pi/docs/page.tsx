import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Remote Pi reference",
  "description": "Phone control, local and cross-PC agent messaging, and optional daemon supervision. Setup, configuration and trust contracts live in the repository guides."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["index", "extension", "mobile", "relay", "messaging", "daemon", "launch", "protocol", "security"]} />;
}
