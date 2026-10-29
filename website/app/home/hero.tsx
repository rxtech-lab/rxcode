"use client";

import Image from "next/image";
import Link from "next/link";
import { TrackedLink } from "../tracked-link";
import { easeOut, RevealWords, useElementProgress } from "./motion";
import {
  AGENTS,
  AppleIcon,
  ArrowRightIcon,
  GITHUB_REPO_URL,
  GitHubIcon,
  ProductScreenshot,
} from "./ui";

export function Hero({
  tag,
  dmgUrl,
  sizeLabel,
}: {
  tag: string;
  dmgUrl: string;
  sizeLabel: string | null;
}) {
  const [stageRef, progress] = useElementProgress<HTMLDivElement>(0.15);
  const t = easeOut(progress);

  return (
    <section className="relative overflow-hidden pt-32 md:pt-40">
      <div className="aurora pointer-events-none absolute inset-x-0 -top-40 h-[900px]" />
      <div className="pointer-events-none absolute inset-0 bg-dots opacity-30 [mask-image:radial-gradient(ellipse_at_top,black_20%,transparent_65%)]" />

      <div className="relative mx-auto flex max-w-[var(--container-max)] flex-col items-center px-6 text-center">
        <Link
          href="/release"
          className="fade-in group inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 py-1 pl-1 pr-3 text-sm text-on-surface-variant backdrop-blur transition-colors hover:border-primary/50 hover:text-on-surface"
        >
          <span className="rounded-full bg-primary px-2 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-widest text-on-primary">
            New
          </span>
          <span>{tag} is out — see what&apos;s new</span>
          <ArrowRightIcon className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" />
        </Link>

        <h1 className="mt-8 max-w-5xl font-display text-5xl font-semibold leading-[1.02] tracking-[-0.04em] md:text-7xl lg:text-[88px]">
          <RevealWords text="Plan the big idea." delay={120} />
          <br />
          <RevealWords
            text="Let your agents ship it."
            delay={420}
            className="text-gradient-primary"
          />
        </h1>

        <p
          className="fade-in mt-7 max-w-2xl text-lg leading-relaxed text-on-surface-variant md:text-xl"
          style={{ animationDelay: "800ms" }}
        >
          RxCode is the native workspace for teams of AI agents. Sprint boards,
          automatic agent routing, schedules, briefings and chat — on your Mac,
          your server, and in your pocket.
        </p>

        <div
          className="fade-in mt-10 flex flex-col gap-3 sm:flex-row"
          style={{ animationDelay: "950ms" }}
        >
          <TrackedLink
            href={dmgUrl}
            analyticsEventName="download_button_click"
            analyticsLabel={`Download for macOS ${tag}`}
            analyticsLocation="hero"
            className="btn-primary"
          >
            <AppleIcon className="h-4 w-4" />
            Download for macOS
            <span className="text-xs font-normal opacity-70">
              {tag}
              {sizeLabel ? ` · ${sizeLabel}` : ""}
            </span>
          </TrackedLink>
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="btn-secondary"
          >
            <GitHubIcon className="h-4 w-4" />
            Star on GitHub
          </a>
        </div>
        <p
          className="fade-in mt-5 font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/60"
          style={{ animationDelay: "1050ms" }}
        >
          Free & open source · macOS 26+ · iOS · Android
        </p>
      </div>

      {/* Product shot tilts back and flattens as it scrolls into view. */}
      <div
        ref={stageRef}
        className="relative mx-auto mt-20 max-w-[var(--container-max)] px-6 [perspective:1600px]"
      >
        <div
          className="relative will-change-transform"
          style={{
            transform: `rotateX(${(1 - t) * 24}deg) scale(${0.88 + t * 0.12}) translateY(${(1 - t) * 40}px)`,
            transformOrigin: "50% 0%",
          }}
        >
          <div
            className="pointer-events-none absolute -inset-10 rounded-[48px] bg-primary/25 blur-[90px]"
            style={{ opacity: 0.35 + t * 0.4 }}
          />
          <div className="relative rounded-[28px] border border-white/10 bg-surface-container-low/80 p-2 shadow-[0_40px_120px_-30px_rgba(0,0,0,0.9)] backdrop-blur">
            <div className="flex items-center gap-1.5 px-3 pb-2 pt-1">
              <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
              <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
              <span className="h-3 w-3 rounded-full bg-[#28c840]" />
            </div>
            <div className="rounded-[20px]">
              <ProductScreenshot src="/screenshot/demo/workspace.webp" alt="RxCode desktop chat showing a fictional Orbit Studio conversation" priority />
            </div>
          </div>
        </div>
      </div>

      <AgentMarquee />
    </section>
  );
}

function AgentMarquee() {
  const row = [...AGENTS, ...AGENTS];
  return (
    <div className="relative mt-24 pb-8">
      <p className="mb-8 text-center font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/60">
        Works with the agents you already use
      </p>
      <div className="marquee-mask overflow-hidden">
        <div className="marquee flex w-max gap-4">
          {row.map((agent, i) => (
            <div
              key={`${agent.name}-${i}`}
              aria-hidden={i >= AGENTS.length}
              data-morph="hero"
              className="flex items-center gap-3 rounded-2xl border border-white/8 bg-white/[0.03] pl-5 pr-8 py-3"
            >
              <Image
                src={agent.logo}
                alt=""
                width={24}
                height={24}
                unoptimized
                className="h-6 w-6"
              />
              <span className="whitespace-nowrap text-sm font-medium text-on-surface">
                {agent.name}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
