"use client";

import Image from "next/image";
import type { CSSProperties, ReactNode } from "react";
import { TrackedLink } from "../tracked-link";
import {
  easeOut,
  range,
  Reveal,
  ScrollScene,
  useLeaveProgress,
  useSceneProgress,
} from "./motion";
import {
  CheckIcon,
  Eyebrow,
  LaptopIcon,
  LockIcon,
  PhoneIcon,
  ServerIcon,
  TestFlightLogo,
} from "./ui";

const POINTS = [
  {
    title: "End-to-end encrypted",
    body: "The relay only ever forwards ciphertext — pair once and every session stays private.",
  },
  {
    title: "Approvals in your pocket",
    body: "Push notifications for tool calls, finished runs and briefings. Approve with a tap.",
  },
  {
    title: "Hand it back anytime",
    body: "Start on your Mac or a headless server, continue on your phone, hand it back.",
  },
];

export type MobileLinks = {
  appStoreUrl?: string;
  testFlightUrl?: string;
  googlePlayUrl?: string;
};

export function Remote({ links }: { links: MobileLinks }) {
  return (
    <ScrollScene
      id="mobile"
      height="320vh"
      className="rounded-t-[48px] bg-background shadow-[0_-40px_120px_-20px_rgba(0,0,0,0.65)]"
      stageClassName="rounded-t-[48px]"
    >
      <div className="pointer-events-none absolute left-1/2 top-1/3 h-[600px] w-[900px] -translate-x-1/2 rounded-full bg-tertiary/10 blur-[140px]" />
      <RemoteStage links={links} />
    </ScrollScene>
  );
}

function RemoteStage({ links }: { links: MobileLinks }) {
  const p = useSceneProgress();
  // Exit: the whole stage pans off to the left, into the sideways panels.
  const leave = useLeaveProgress("mobile");
  // The phone rises in, the Mac and server slide in, then the links lock.
  const arrive = easeOut(range(p, 0, 0.3));
  const flank = easeOut(range(p, 0.12, 0.38));
  const linked = p > 0.4;
  const step = p < 0.55 ? 0 : p < 0.78 ? 1 : 2;

  return (
    <div
      className="relative mx-auto flex h-full max-w-[var(--container-max)] flex-col items-center justify-center px-6 pb-8 pt-24"
      style={{
        transform: `translateX(${-leave * leave * 60}vw) rotate(${-leave * 3}deg)`,
        opacity: 1 - range(leave, 0.2, 0.9),
      }}
    >
      <div className="mx-auto max-w-3xl shrink-0 text-center">
        <Eyebrow>Work from anywhere</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          Your agents keep working.
          <br />
          <span className="text-gradient-cool">Wherever you are.</span>
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          Desktop or server, RxCode Mobile pairs with it in seconds. Follow
          live sessions, approve tool calls, preview your dev server and
          start new runs from iPhone, iPad or Android.
        </p>
      </div>

      <div className="relative mt-8 flex w-full max-w-5xl shrink-0 items-center justify-center">
        <DeviceCard
          icon={<LaptopIcon className="h-6 w-6" />}
          title="Mac"
          subtitle="RxCode desktop"
          highlight={step === 2}
          className="hidden md:flex"
          style={{ transform: `translateX(${(1 - flank) * -120}px)`, opacity: flank }}
        />
        <SyncLink side="left" active={linked} />

        <div
          className="relative z-10 aspect-[9/19.5] shrink-0"
          style={{
            height: "min(34vh, 400px)",
            transform: `translateY(${(1 - arrive) * 160}px) scale(${0.85 + arrive * 0.15})`,
            opacity: 0.2 + arrive * 0.8,
          }}
        >
          <div className="h-full rounded-[40px] border border-white/15 bg-black p-2 shadow-[0_50px_120px_-30px_rgba(133,207,255,0.35)]">
            <div className="relative h-full overflow-hidden rounded-[32px]">
              <div className="absolute left-1/2 top-2 z-10 h-5 w-20 -translate-x-1/2 rounded-full bg-black" />
              <div className="h-full bg-[#07132b] px-3 pt-10 text-[10px]" role="img" aria-label="Illustration of a fictional Orbit Studio mobile session">
                <div className="border-b border-white/10 pb-3 font-semibold text-on-surface">Orbit Studio</div>
                <div className="mt-4 ml-3 rounded-xl bg-white/10 p-2 text-on-surface">Review the activity timeline.</div>
                <div className="mt-4 space-y-2 text-on-surface-variant">
                  <p className="font-semibold text-primary">Ready for review</p>
                  <p>The timeline now groups events by day and supports keyboard navigation.</p>
                  <p>All checks passed.</p>
                </div>
              </div>
              <PhoneMoments step={step} />
            </div>
          </div>
        </div>

        <SyncLink side="right" active={linked} />
        <DeviceCard
          icon={<ServerIcon className="h-6 w-6" />}
          title="Server"
          subtitle="Headless runner"
          className="hidden md:flex"
          style={{ transform: `translateX(${(1 - flank) * 120}px)`, opacity: flank }}
        />
      </div>

      <div className="mt-8 flex shrink-0 gap-2">
        {POINTS.map((point, i) => (
          <span
            key={point.title}
            className={`h-1 rounded-full transition-all duration-500 ${
              i === step ? "w-10 bg-tertiary" : "w-4 bg-white/15"
            }`}
          />
        ))}
      </div>

      <div className="relative mt-4 h-16 w-full max-w-2xl shrink-0 text-center">
        {POINTS.map((point, i) => (
          <div
            key={point.title}
            className="absolute inset-0 transition-all duration-700 ease-out"
            style={{
              opacity: i === step ? 1 : 0,
              transform: `translateY(${(i - step) * 20}px)`,
            }}
            aria-hidden={i !== step}
          >
            <h3 className="font-semibold text-on-surface">{point.title}</h3>
            <p className="mt-1.5 text-sm leading-relaxed text-on-surface-variant md:text-base">
              {point.body}
            </p>
          </div>
        ))}
      </div>
      <StoreLinks links={links} />
    </div>
  );
}

/** What the phone screen shows for each point. */
function PhoneMoments({ step }: { step: number }) {
  const shown = (i: number) =>
    i === step ? "translate-y-0 opacity-100" : i < step ? "-translate-y-4 opacity-0" : "translate-y-4 opacity-0";

  return (
    <>
      <div className={`absolute inset-x-2 bottom-4 flex items-center justify-center gap-1.5 whitespace-nowrap rounded-full border border-tertiary/30 bg-black/70 px-2 py-1.5 text-[10px] text-tertiary backdrop-blur transition-all duration-500 ${shown(0)}`}>
        <LockIcon className="h-3 w-3" />
        Encrypted session
      </div>

      <div className={`absolute inset-x-2.5 top-9 rounded-2xl border border-white/10 bg-surface-container-high/95 p-2.5 shadow-xl backdrop-blur transition-all duration-500 ${shown(1)}`}>
        <div className="flex items-center gap-1.5 font-mono text-[9px] uppercase tracking-wider text-on-surface-variant/80">
          <PhoneIcon className="h-3 w-3 text-tertiary" />
          Approval needed
        </div>
        <p className="mt-1 text-[11px] leading-snug text-on-surface">
          Claude Code wants to run <span className="font-mono text-tertiary">bun test</span>
        </p>
        <div className="mt-2 grid grid-cols-2 gap-1.5 text-[10px] font-medium">
          <span className="rounded-lg bg-white/8 py-1 text-center text-on-surface-variant">Deny</span>
          <span className="rounded-lg bg-tertiary py-1 text-center text-background">Approve</span>
        </div>
      </div>

      <div className={`absolute inset-x-2 bottom-4 flex items-center justify-center gap-1.5 whitespace-nowrap rounded-full border border-emerald-400/30 bg-black/70 px-2 py-1.5 text-[10px] text-emerald-300 backdrop-blur transition-all duration-500 ${shown(2)}`}>
        <CheckIcon className="h-3 w-3" />
        Continued on Mac
      </div>
    </>
  );
}

function DeviceCard({
  icon,
  title,
  subtitle,
  highlight = false,
  className = "",
  style,
}: {
  icon: ReactNode;
  title: string;
  subtitle: string;
  highlight?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <div
      className={`glass-panel w-44 shrink-0 flex-col items-center gap-3 rounded-3xl p-6 text-center transition-shadow duration-500 ${
        highlight ? "shadow-[0_0_0_1px_rgba(52,211,153,0.45),0_0_60px_-10px_rgba(52,211,153,0.5)]" : ""
      } ${className}`}
      style={style}
    >
      <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-white/8 text-on-surface">
        {icon}
      </span>
      <span className="font-semibold text-on-surface">{title}</span>
      <span className="text-xs text-on-surface-variant/70">{subtitle}</span>
      <span className="mt-1 inline-flex items-center gap-1.5 rounded-full bg-emerald-400/10 px-2 py-0.5 text-[10px] text-emerald-300">
        <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" />
        Online
      </span>
    </div>
  );
}

function SyncLink({ side, active }: { side: "left" | "right"; active: boolean }) {
  return (
    <div className="relative hidden h-px flex-1 md:block">
      <div className="absolute inset-0 bg-white/10" />
      <div
        className={`sync-flow absolute inset-0 transition-opacity duration-700 ${
          side === "right" ? "sync-flow-rev" : ""
        } ${active ? "opacity-100" : "opacity-0"}`}
      />
      <span
        className={`absolute left-1/2 top-1/2 flex h-7 w-7 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-white/15 bg-background text-tertiary transition-transform duration-700 ${
          active ? "scale-100" : "scale-0"
        }`}
      >
        <LockIcon className="h-3.5 w-3.5" />
      </span>
    </div>
  );
}

function StoreLinks({ links }: { links: MobileLinks }) {
  const { appStoreUrl, testFlightUrl, googlePlayUrl } = links;
  if (!appStoreUrl && !testFlightUrl && !googlePlayUrl) return null;

  return (
    <Reveal className="mt-6 flex flex-wrap items-center justify-center gap-3">
      {appStoreUrl ? (
        <TrackedLink
          href={appStoreUrl}
          analyticsEventName="app_store_button_click"
          analyticsLabel="Download on the App Store"
          analyticsLocation="mobile_companion"
          target="_blank"
          rel="noreferrer"
          className="inline-block w-fit transition-opacity hover:opacity-85 active:scale-95"
        >
          <Image src="/download-appstore.svg" alt="Download on the App Store" width={540} height={160} unoptimized className="h-[52px] w-auto" />
        </TrackedLink>
      ) : null}
      {testFlightUrl ? (
        <TrackedLink
          href={testFlightUrl}
          analyticsEventName="testflight_button_click"
          analyticsLabel="Download iOS external test on TestFlight"
          analyticsLocation="mobile_companion"
          target="_blank"
          rel="noreferrer"
          aria-label="Download iOS external test on TestFlight"
          className="inline-flex h-[52px] w-[176px] items-center gap-3 rounded-[7px] border border-[#a6a6a6] bg-black px-3.5 text-white transition-[opacity,transform] hover:opacity-85 active:scale-95"
        >
          <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#0a84ff] text-white">
            <TestFlightLogo className="h-6 w-6" />
          </span>
          <span className="flex flex-col items-start leading-none">
            <span className="text-[9px] tracking-wide text-white/85">Join beta on</span>
            <span className="mt-1 text-[20px] font-semibold">TestFlight</span>
          </span>
        </TrackedLink>
      ) : null}
      {googlePlayUrl ? (
        <TrackedLink
          href={googlePlayUrl}
          analyticsEventName="google_play_button_click"
          analyticsLabel="Download Android external test on Google Play"
          analyticsLocation="mobile_companion"
          target="_blank"
          rel="noreferrer"
          aria-label="Download Android external test on Google Play"
          className="inline-block w-fit transition-opacity hover:opacity-85 active:scale-95"
        >
          <Image src="/download-google-play.svg" alt="Get it on Google Play" width={540} height={160} unoptimized className="h-[52px] w-auto" />
        </TrackedLink>
      ) : null}
    </Reveal>
  );
}
