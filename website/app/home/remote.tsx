"use client";

import Image from "next/image";
import type { CSSProperties, ReactNode } from "react";
import { TrackedLink } from "../tracked-link";
import { easeOut, Reveal, useElementProgress } from "./motion";
import {
  CheckIcon,
  Eyebrow,
  LaptopIcon,
  LockIcon,
  PhoneIcon,
  ScreenshotPlaceholder,
  ServerIcon,
  TestFlightLogo,
} from "./ui";

const POINTS = [
  "End-to-end encrypted — the relay only ever forwards ciphertext.",
  "Push notifications for approvals, finished runs and briefings.",
  "Start on your Mac or a headless server, continue on your phone, hand it back.",
];

export type MobileLinks = {
  appStoreUrl?: string;
  testFlightUrl?: string;
  googlePlayUrl?: string;
};

export function Remote({ links }: { links: MobileLinks }) {
  const [ref, progress] = useElementProgress<HTMLDivElement>(0.1);
  const t = easeOut(progress);

  return (
    <section id="mobile" className="relative overflow-hidden py-32">
      <div className="pointer-events-none absolute left-1/2 top-1/3 h-[600px] w-[900px] -translate-x-1/2 rounded-full bg-tertiary/10 blur-[140px]" />
      <div className="relative mx-auto max-w-[var(--container-max)] px-6">
        <Reveal className="mx-auto max-w-3xl text-center">
          <Eyebrow>Work from anywhere</Eyebrow>
          <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
            Your agents keep working.
            <br />
            <span className="text-gradient-cool">Wherever you are.</span>
          </h2>
          <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-on-surface-variant">
            Desktop or server, RxCode Mobile pairs with it in seconds. Follow
            live sessions, approve tool calls, preview your dev server and
            start new runs from iPhone, iPad or Android.
          </p>
        </Reveal>

        <div ref={ref} className="relative mx-auto mt-20 flex max-w-5xl items-center justify-center">
          <DeviceCard
            icon={<LaptopIcon className="h-6 w-6" />}
            title="Mac"
            subtitle="RxCode desktop"
            className="hidden md:flex"
            style={{ transform: `translateX(${(1 - t) * -80}px)`, opacity: 0.2 + t * 0.8 }}
          />
          <SyncLink side="left" active={t > 0.6} />

          <div
            className="relative z-10 w-[240px] shrink-0 md:w-[280px]"
            style={{ transform: `translateY(${(1 - t) * 120}px) scale(${0.9 + t * 0.1})` }}
          >
            <div className="rounded-[46px] border border-white/15 bg-black p-2.5 shadow-[0_50px_120px_-30px_rgba(133,207,255,0.35)]">
              <div className="relative overflow-hidden rounded-[38px]">
                <div className="absolute left-1/2 top-2.5 z-10 h-6 w-24 -translate-x-1/2 rounded-full bg-black" />
                <ScreenshotPlaceholder label="RxCode Mobile" aspect="aspect-[9/19.5]" />
              </div>
            </div>
          </div>

          <SyncLink side="right" active={t > 0.6} />
          <DeviceCard
            icon={<ServerIcon className="h-6 w-6" />}
            title="Server"
            subtitle="Headless runner"
            className="hidden md:flex"
            style={{ transform: `translateX(${(1 - t) * 80}px)`, opacity: 0.2 + t * 0.8 }}
          />
        </div>

        <div className="mx-auto mt-16 grid max-w-4xl grid-cols-1 gap-4 md:grid-cols-3">
          {POINTS.map((point, i) => (
            <Reveal key={point} delay={i * 100} className="glass-panel flex gap-3 rounded-2xl p-5">
              {i === 0 ? (
                <LockIcon className="mt-0.5 h-5 w-5 shrink-0 text-tertiary" />
              ) : i === 1 ? (
                <PhoneIcon className="mt-0.5 h-5 w-5 shrink-0 text-tertiary" />
              ) : (
                <CheckIcon className="mt-0.5 h-5 w-5 shrink-0 text-tertiary" />
              )}
              <span className="text-sm leading-relaxed text-on-surface-variant">{point}</span>
            </Reveal>
          ))}
        </div>

        <StoreLinks links={links} />
      </div>
    </section>
  );
}

function DeviceCard({
  icon,
  title,
  subtitle,
  className = "",
  style,
}: {
  icon: ReactNode;
  title: string;
  subtitle: string;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <div
      className={`glass-panel w-44 shrink-0 flex-col items-center gap-3 rounded-3xl p-6 text-center ${className}`}
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
    <Reveal className="mt-12 flex flex-wrap items-center justify-center gap-3">
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
