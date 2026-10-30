import { AgentRouting } from "./home/agent-routing";
import { AgentTeam } from "./home/agent-team";
import { SupportedAgents } from "./home/agents";
import { AllInOne } from "./home/all-in-one";
import { FlowcyCloud } from "./home/flowcy";
import { Hero } from "./home/hero";
import { MorphLayer, type MorphTransition } from "./home/morph";
import { Remote } from "./home/remote";
import { ClosingCTA, Screenshots } from "./home/sections";
import { SprintBoard } from "./home/sprint-board";
import { formatSize, getLatestRelease } from "./lib/release";
import { SiteFooter } from "./site-footer";
import { SiteNav } from "./site-nav";

// The hero chips drop onto the board; the board glides into the router.
// Every other section has its own exit, driven inside the section itself.
const MORPHS: MorphTransition[] = [
  { from: "hero", to: "sprint", section: "sprint", startAt: 0.5 },
  {
    from: "board",
    to: "router",
    section: "routing",
    blank: true,
    path: "glide",
    span: 1.8,
    flight: 0.85,
  },
];

export default async function Home() {
  const release = await getLatestRelease();
  const sizeLabel = formatSize(release.sizeBytes);
  const mobileLinks = {
    appStoreUrl: process.env.NEXT_PUBLIC_APP_STORE_URL?.trim() || undefined,
    testFlightUrl:
      process.env.NEXT_PUBLIC_IOS_EXTERNAL_TESTFLIGHT_URL?.trim() || undefined,
    googlePlayUrl:
      process.env.NEXT_PUBLIC_GOOGLE_PLAY_EXTERNAL_TEST_URL?.trim() || undefined,
  };

  return (
    <>
      <SiteNav dmgUrl={release.dmgUrl} />
      <main>
        <Hero tag={release.tag} dmgUrl={release.dmgUrl} sizeLabel={sizeLabel} />
        <SprintBoard />
        <AgentRouting />
        <AgentTeam />
        <Remote links={mobileLinks} />
        <AllInOne />
        <FlowcyCloud />
        <SupportedAgents />
        <Screenshots />
        <ClosingCTA tag={release.tag} dmgUrl={release.dmgUrl} />
      </main>
      <SiteFooter />
      <MorphLayer transitions={MORPHS} />
    </>
  );
}
