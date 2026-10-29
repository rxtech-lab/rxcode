import { AgentRouting } from "./home/agent-routing";
import { AgentTeam } from "./home/agent-team";
import { AllInOne } from "./home/all-in-one";
import { Hero } from "./home/hero";
import { TopNav } from "./home/nav";
import { Remote } from "./home/remote";
import {
  ClosingCTA,
  FlowcyCloud,
  Footer,
  Screenshots,
  SupportedAgents,
} from "./home/sections";
import { SprintBoard } from "./home/sprint-board";
import { formatSize, getLatestRelease } from "./lib/release";

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
      <TopNav dmgUrl={release.dmgUrl} />
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
      <Footer />
    </>
  );
}
