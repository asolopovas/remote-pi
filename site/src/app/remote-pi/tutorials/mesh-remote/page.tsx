import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Remote mesh",
  "description": "Agents on different PCs route messages through a relay. Delivery acknowledgements are not content replies; review the messaging and trust contracts."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["extension", "messaging", "relay", "protocol"]} />;
}
