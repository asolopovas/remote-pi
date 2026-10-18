import type { Metadata } from "next";
import { GuidePage } from "@/components/repository-guides";

export const metadata: Metadata = {
  "title": "Layouts and tasks in Cockpit",
  "description": "Keep workspace layouts and repeatable development tasks with your project. The owning guides define their formats and execution behavior."
};

export default function Page() {
  return <GuidePage title={metadata.title as string} description={metadata.description as string} guides={["cockpit", "layouts", "tasks", "cli"]} />;
}
