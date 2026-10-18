import { siteUrl } from "@/lib/site-url.mjs";
import type { Metadata } from "next";
import { Hero } from "@/components/landing/hero";
import { Install } from "@/components/landing/install";
import { Pillars, GetApp, Strip, GithubCTA } from "@/components/landing/sections";
import { RevealController } from "@/components/landing/reveal-controller";

const pageTitle = "Remote Pi: your coding agents, in your pocket";
const pageDescription =
  "Pair your phone once, then drive any Pi coding agent from it: keep a fleet running 24/7 and link every machine into one mesh. Open source, self-hostable.";

const ownedSiteUrl = siteUrl(process.env.NEXT_PUBLIC_SITE_URL);

export const metadata: Metadata = {
  title: { absolute: pageTitle },
  description: pageDescription,
  openGraph: {
    type: "website",
    url: ownedSiteUrl ? `${ownedSiteUrl}/remote-pi` : undefined,
    title: pageTitle,
    description: pageDescription,
    siteName: "Remote Pi",
  },
  twitter: {
    card: "summary_large_image",
    title: pageTitle,
    description: pageDescription,
  },
};

export default function Home() {
  return (
    <>
      <Hero />
      <Pillars />
      <Install />
      <GetApp />
      <Strip />
      <GithubCTA />
      <RevealController />
    </>
  );
}
