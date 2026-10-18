import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Getting started",
  "description": "Build the host extension and mobile client from source, configure your relay, then pair your phone. Follow the maintained project guides below."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["extension", "mobile", "relay", "launch", "security"]} />;
}
