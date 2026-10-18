import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Build the Remote Pi app from source",
  "description": "Binary downloads and upstream store listings are disabled. Build your own mobile client and host extension, then configure your own relay and pair them."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["mobile", "extension", "relay", "security"]} />;
}
