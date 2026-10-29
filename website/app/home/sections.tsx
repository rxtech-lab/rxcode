import { Brand } from "../brand";
import Image from "next/image";
import Link from "next/link";
import type { CSSProperties } from "react";
import { TrackedLink } from "../tracked-link";
import { Reveal } from "./motion";
import {
  AGENTS,
  AppleIcon,
  ArrowRightIcon,
  BoltIcon,
  CloudIcon,
  Eyebrow,
  FLOWCY_URL,
  GITHUB_REPO_URL,
  GitHubIcon,
  LockIcon,
  ScreenshotPlaceholder,
  SparkIcon,
} from "./ui";

/* ------------------------------------------------------------------ */
/*  Flowcy cloud                                                       */
/* ------------------------------------------------------------------ */

const FLOWCY_FEATURES = [
  {
    icon: <CloudIcon className="h-5 w-5" />,
    title: "Shared cloud boards",
    body: "One workspace for every project, synced to every teammate and every device.",
  },
  {
    icon: <BoltIcon className="h-5 w-5" />,
    title: "Runs on the right machine",
    body: "Cloud tasks are claimed by exactly one device, so work never runs twice.",
  },
  {
    icon: <LockIcon className="h-5 w-5" />,
    title: "Secrets stay secret",
    body: "Encrypted on-device with passkeys. The cloud never sees plaintext.",
  },
  {
    icon: <SparkIcon className="h-5 w-5" />,
    title: "Releases, CI & docs",
    body: "Ship releases, watch CI, review dependency updates and publish docs together.",
  },
];

const TEAM = ["AL", "MK", "JS", "RW", "TN", "EV"];

export function FlowcyCloud() {
  return (
    <section id="flowcy" className="relative overflow-hidden py-32">
      <div className="mx-auto grid max-w-[var(--container-max)] grid-cols-1 items-center gap-16 px-6 lg:grid-cols-2">
        <div>
          <Reveal>
            <Eyebrow>Flowcy Cloud</Eyebrow>
            <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
              Your team&apos;s
              <br />
              <span className="text-gradient-primary">cloud workspace.</span>
            </h2>
            <p className="mt-5 max-w-xl text-lg leading-relaxed text-on-surface-variant">
              Flowcy brings your boards, agents and people together. Invite
              your team, assign work to humans or agents, and let every
              device pick up where the last one left off.
            </p>
          </Reveal>
          <div className="mt-10 grid grid-cols-1 gap-3 sm:grid-cols-2">
            {FLOWCY_FEATURES.map((feature, i) => (
              <Reveal key={feature.title} delay={i * 90} className="glass-panel rounded-2xl p-5">
                <span className="text-primary">{feature.icon}</span>
                <h3 className="mt-3 font-semibold text-on-surface">{feature.title}</h3>
                <p className="mt-1.5 text-sm leading-relaxed text-on-surface-variant">
                  {feature.body}
                </p>
              </Reveal>
            ))}
          </div>
          <Reveal delay={200} className="mt-8">
            <a href={FLOWCY_URL} target="_blank" rel="noreferrer" className="btn-secondary">
              Explore Flowcy
              <ArrowRightIcon className="h-4 w-4" />
            </a>
          </Reveal>
        </div>

        <Reveal className="relative mx-auto aspect-square w-full max-w-[520px] [container-type:inline-size]" y={48}>
          <div className="absolute inset-0 rounded-full border border-white/5" />
          <div className="absolute inset-[14%] rounded-full border border-white/8" />
          <div className="absolute inset-[30%] rounded-full border border-primary/20" />
          <div className="absolute inset-[38%] flex items-center justify-center rounded-full bg-gradient-to-br from-primary to-[#00cfbb] shadow-[0_0_120px_20px_rgba(0,207,187,0.35)]">
            <CloudIcon className="h-1/2 w-1/2 text-white" />
          </div>
          <div className="orbit absolute inset-0">
            {TEAM.map((initials, i) => (
              <span
                key={initials}
                className="orbit-item absolute left-1/2 top-1/2 flex h-12 w-12 items-center justify-center rounded-full border border-white/15 bg-surface-container-high text-sm font-semibold text-on-surface shadow-xl"
                style={{ "--angle": `${(360 / TEAM.length) * i}deg`, "--radius": "43cqw" } as CSSProperties}
              >
                <span className="orbit-counter">{initials}</span>
              </span>
            ))}
          </div>
          <div className="orbit orbit-slow absolute inset-[14%]">
            {AGENTS.slice(0, 4).map((agent, i) => (
              <span
                key={agent.name}
                className="orbit-item absolute left-1/2 top-1/2 flex h-10 w-10 items-center justify-center rounded-2xl border border-white/10 bg-black/70 backdrop-blur"
                style={{ "--angle": `${90 * i + 45}deg`, "--radius": "29cqw" } as CSSProperties}
              >
                <Image src={agent.logo} alt="" width={20} height={20} unoptimized className="orbit-counter h-5 w-5" />
              </span>
            ))}
          </div>
        </Reveal>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/*  Supported agents                                                   */
/* ------------------------------------------------------------------ */

export function SupportedAgents() {
  return (
    <section id="agents" className="relative py-32">
      <div className="mx-auto max-w-[var(--container-max)] px-6">
        <Reveal className="mx-auto max-w-3xl text-center">
          <Eyebrow>Every agent, one workspace</Eyebrow>
          <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
            Bring the agents you love.
          </h2>
          <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-on-surface-variant">
            Claude Code and Codex are built in. Antigravity, Cursor, OpenCode,
            Gemini CLI and any Agent Client Protocol runtime install from the
            ACP registry in one click — same chat, approvals and board.
          </p>
        </Reveal>

        <div className="mt-16 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          {AGENTS.map((agent, i) => (
            <Reveal key={agent.name} delay={i * 60} className="agent-tile group glass-panel relative flex flex-col items-center gap-4 overflow-hidden rounded-3xl px-4 py-8 text-center">
              <span className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_50%_0%,rgba(0,207,187,0.22),transparent_65%)] opacity-0 transition-opacity duration-500 group-hover:opacity-100" />
              <span className="relative flex h-16 w-16 items-center justify-center rounded-2xl border border-white/10 bg-black/40 transition-transform duration-500 group-hover:-translate-y-1 group-hover:scale-110">
                <Image src={agent.logo} alt={`${agent.name} logo`} width={32} height={32} unoptimized className="h-8 w-8" />
              </span>
              <span className="relative">
                <span className="block font-semibold text-on-surface">{agent.name}</span>
                <span className="mt-0.5 block text-xs text-on-surface-variant/70">{agent.vendor}</span>
              </span>
            </Reveal>
          ))}
          <Reveal delay={AGENTS.length * 60} className="glass-panel flex flex-col items-center justify-center gap-2 rounded-3xl border-dashed px-4 py-8 text-center">
            <span className="font-display text-3xl font-semibold text-primary">+ ACP</span>
            <span className="text-xs text-on-surface-variant/70">Any Agent Client Protocol runtime</span>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/*  Screenshots (placeholders until new captures are ready)            */
/* ------------------------------------------------------------------ */

const SHOTS = [
  { label: "Sprint board", className: "md:col-span-2", aspect: "aspect-[16/9]" },
  { label: "Agent routing", className: "", aspect: "aspect-[4/5] md:aspect-auto md:h-full" },
  { label: "Daily briefing", className: "", aspect: "aspect-[4/3]" },
  { label: "Schedules", className: "", aspect: "aspect-[4/3]" },
  { label: "Mobile", className: "", aspect: "aspect-[4/3]" },
  { label: "Flowcy Cloud", className: "md:col-span-3", aspect: "aspect-[21/9]" },
];

export function Screenshots() {
  return (
    <section id="screenshots" className="relative py-32">
      <div className="mx-auto max-w-[var(--container-max)] px-6">
        <Reveal className="mb-14 flex flex-col justify-between gap-6 md:flex-row md:items-end">
          <div>
            <Eyebrow>Gallery</Eyebrow>
            <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
              See it in action.
            </h2>
          </div>
          <p className="max-w-md text-on-surface-variant">
            A native SwiftUI app with Liquid Glass on macOS, plus companion
            apps for iOS and Android.
          </p>
        </Reveal>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          {SHOTS.map((shot, i) => (
            <Reveal
              key={shot.label}
              delay={(i % 3) * 90}
              className={`overflow-hidden rounded-[28px] border border-white/8 ${shot.className}`}
            >
              <ScreenshotPlaceholder label={shot.label} aspect={shot.aspect} />
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/*  Closing CTA + footer                                               */
/* ------------------------------------------------------------------ */

export function ClosingCTA({ tag, dmgUrl }: { tag: string; dmgUrl: string }) {
  return (
    <section className="relative overflow-hidden py-40">
      <div className="aurora pointer-events-none absolute inset-x-0 top-1/2 h-[700px] -translate-y-1/2 opacity-70" />
      <Reveal className="relative mx-auto max-w-3xl px-6 text-center">
        <h2 className="font-display text-5xl font-semibold tracking-[-0.04em] md:text-7xl">
          From idea to shipped.
          <br />
          <span className="text-gradient-primary">RxCode has it all.</span>
        </h2>
        <p className="mx-auto mt-6 max-w-xl text-lg text-on-surface-variant">
          Free and open source. Download {tag} and put your agent team to work.
        </p>
        <div className="mt-10 flex flex-col justify-center gap-3 sm:flex-row">
          <TrackedLink
            href={dmgUrl}
            analyticsEventName="download_button_click"
            analyticsLabel={`Download RxCode ${tag}`}
            analyticsLocation="cta"
            className="btn-primary"
          >
            <AppleIcon className="h-4 w-4" />
            Download RxCode {tag}
          </TrackedLink>
          <Link href="/release" className="btn-secondary">
            Release notes
            <ArrowRightIcon className="h-4 w-4" />
          </Link>
        </div>
      </Reveal>
    </section>
  );
}

export function Footer() {
  const year = new Date().getFullYear();
  const links = [
    { href: "/privacy", label: "Privacy" },
    { href: "/user-agreement", label: "User Agreement" },
    { href: "/release", label: "Release Notes" },
  ];
  return (
    <footer className="border-t border-white/8">
      <div className="mx-auto flex max-w-[var(--container-max)] flex-col items-start justify-between gap-6 px-6 py-12 md:flex-row md:items-center">
        <div className="flex items-center gap-3">
          <Image src="/icon.svg" alt="" width={28} height={28} unoptimized className="h-7 w-7" />
          <div>
            <span className="font-display text-lg font-semibold text-on-surface"><Brand /></span>
            <span className="block text-xs text-on-surface-variant/60">
              © {year} RxCode. All rights reserved.
            </span>
          </div>
        </div>
        <nav className="flex flex-wrap items-center gap-6 text-sm">
          {links.map((link) => (
            <Link key={link.href} href={link.href} className="text-on-surface-variant transition-colors hover:text-on-surface">
              {link.label}
            </Link>
          ))}
          <a href={FLOWCY_URL} target="_blank" rel="noreferrer" className="text-on-surface-variant transition-colors hover:text-on-surface">
            Flowcy
          </a>
          <a href={GITHUB_REPO_URL} target="_blank" rel="noreferrer" aria-label="GitHub" className="text-on-surface-variant transition-colors hover:text-on-surface">
            <GitHubIcon className="h-4 w-4" />
          </a>
        </nav>
      </div>
    </footer>
  );
}
