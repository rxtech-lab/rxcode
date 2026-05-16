import Image from "next/image";
import Link from "next/link";
import { formatSize, getLatestRelease } from "./lib/release";

const GITHUB_REPO_URL = "https://github.com/rxtech-lab/rxcode";

const FEATURE_CARDS = [
  {
    eyebrow: "Agent Runtime",
    title: "Support multiple agents",
    description:
      "Run Claude Code, Codex, Gemini CLI, OpenCode, and any Agent Client Protocol runtime from the same native workspace. Pick the client and model per session without changing how you manage projects.",
    image: "/screenshot/acp1.png",
    alt: "RxCode running an ACP client session with model and usage controls visible",
    width: 2014,
    height: 1932,
    className: "md:col-span-2",
  },
  {
    eyebrow: "ACP Registry",
    title: "Install ACP clients directly",
    description:
      "Browse the public ACP registry from Settings, install compatible clients in one step, and add registry agents to the chat model picker without manual setup.",
    image: "/screenshot/acp2.png",
    alt: "RxCode Settings window showing ACP client registry installation",
    width: 1496,
    height: 1564,
    className: "md:col-span-1",
  },
  {
    eyebrow: "Native macOS",
    title: "Liquid glass, pure SwiftUI",
    description:
      "A lightweight native app with macOS materials, responsive SwiftUI views, and no bundled browser runtime. Fast to launch, fast to stream, and designed for the desktop.",
    image: "/screenshot/screenshot2.png",
    alt: "RxCode native macOS workspace with sidebar, prompt composer, and status bar",
    width: 3638,
    height: 2196,
    className: "md:col-span-1",
  },
  {
    eyebrow: "Run Profiles",
    title: "Launch project workflows",
    description:
      "Create repeatable project tasks, run them from the toolbar, and inspect command output without leaving the app.",
    image: "/screenshot/run-profile.png",
    alt: "RxCode run profile controls and output inspector",
    width: 3058,
    height: 2048,
    className: "md:col-span-2",
  },
  {
    eyebrow: "MCP",
    title: "MCP support built in",
    description:
      "Configure, inspect, and test Model Context Protocol servers from Settings, including local and project-scoped servers.",
    image: "/screenshot/mcp.png",
    alt: "RxCode Settings window showing MCP server configuration",
    width: 1334,
    height: 1024,
    className: "md:col-span-2",
  },
  {
    eyebrow: "Menu Bar Extra",
    title: "Track progress and usage at a glance",
    description:
      "Monitor active sessions, pending checks, and Claude Code or Codex usage limits from the menu bar without opening the main window.",
    image: "/screenshot/menubar.png",
    alt: "RxCode menu bar extra showing Codex usage limits and session progress",
    width: 726,
    height: 648,
    className: "md:col-span-1",
  },
  {
    eyebrow: "Editor Handoff",
    title: "Open in your code editor",
    description:
      "Jump directly into VS Code, Cursor, Zed, Xcode, JetBrains IDEs, Finder, Terminal, or Warp so you can manage code in the editor you choose.",
    image: "/screenshot/openineditor.png",
    alt: "RxCode editor menu with VS Code, Cursor, Zed, Finder, Terminal, and Xcode options",
    width: 346,
    height: 722,
    className: "md:col-span-1",
  },
  {
    eyebrow: "Thread Review",
    title: "Track changes easily",
    description:
      "See every file changed in a thread with additions and deletions summarized together, even while multiple sessions keep running in parallel.",
    image: "/screenshot/changes-track.png",
    alt: "RxCode thread review panel listing files changed by an agent session",
    width: 1094,
    height: 1850,
    className: "md:col-span-2",
  },
];

export default async function Home() {
  const release = await getLatestRelease();
  const sizeLabel = formatSize(release.sizeBytes);

  return (
    <>
      <TopNav release={release} />
      <main className="pt-24">
        <Hero release={release} sizeLabel={sizeLabel} />
        <AppPreview />
        <SupportedAgents />
        <FeatureBento />
        <CTA release={release} />
      </main>
      <Footer />
    </>
  );
}

function TopNav({
  release,
}: {
  release: Awaited<ReturnType<typeof getLatestRelease>>;
}) {
  return (
    <nav className="fixed top-0 inset-x-0 z-50 border-b border-surface-variant bg-background/80 backdrop-blur">
      <div className="max-w-[var(--container-max)] mx-auto px-6 h-16 flex items-center justify-between">
        <div className="flex items-center gap-10">
          <span className="font-display text-2xl font-bold text-primary tracking-tight">
            RxCode
          </span>
          <div className="hidden md:flex gap-7 text-sm">
            <a
              href="#features"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Features
            </a>
            <a
              href="#agents"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Supported Agents
            </a>
            <Link
              href="/release"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Release Notes
            </Link>
            <a
              href={GITHUB_REPO_URL}
              target="_blank"
              rel="noreferrer"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              GitHub
            </a>
          </div>
        </div>
        <a
          href={release.dmgUrl}
          className="hidden sm:inline-flex items-center gap-2 bg-primary text-on-primary px-4 py-2 font-mono text-[11px] tracking-widest uppercase border border-primary hover:bg-transparent hover:text-primary transition-colors"
        >
          Download for macOS
        </a>
      </div>
    </nav>
  );
}

function Hero({
  release,
  sizeLabel,
}: {
  release: Awaited<ReturnType<typeof getLatestRelease>>;
  sizeLabel: string | null;
}) {
  return (
    <section className="relative overflow-hidden">
      <div className="absolute inset-0 bg-grid opacity-60 [mask-image:radial-gradient(ellipse_at_top,black_30%,transparent_70%)]" />
      <div className="relative max-w-[var(--container-max)] mx-auto px-6 pt-20 pb-16 flex flex-col items-center text-center">
        <Link
          href="/release"
          className="inline-flex items-center gap-2 px-3 py-1.5 border border-primary text-primary font-mono text-[11px] tracking-widest uppercase bg-primary/10 hover:bg-primary/20 transition-colors"
        >
          <span className="inline-block w-1.5 h-1.5 bg-primary rounded-full animate-pulse" />
          Latest release · {release.tag}
        </Link>

        <h1 className="mt-6 font-display text-5xl md:text-6xl lg:text-7xl font-bold tracking-tight max-w-4xl leading-[1.05]">
          The Visual Command Center for{" "}
          <span className="text-gradient-primary">AI Coding Agents</span>
        </h1>

        <p className="mt-6 text-lg text-on-surface-variant max-w-2xl leading-relaxed">
          Supercharge your AI coding workflow with a native macOS app. Manage
          agent sessions, browse your project, review AI-generated diffs, and
          approve tool calls — all without leaving your desktop.
        </p>

        <div className="mt-10 flex flex-col sm:flex-row gap-3">
          <a
            href={release.dmgUrl}
            className="inline-flex items-center justify-center gap-3 bg-primary text-on-primary px-8 py-3.5 font-mono text-xs tracking-widest uppercase border border-primary hover:bg-transparent hover:text-primary transition-colors active:scale-95"
          >
            <AppleIcon className="w-4 h-4" />
            Download for macOS
            <span className="opacity-70">·</span>
            <span className="opacity-70 normal-case tracking-normal text-[11px]">
              {release.tag}
              {sizeLabel ? ` · ${sizeLabel}` : ""}
            </span>
          </a>
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center justify-center gap-2 border border-outline text-on-surface px-8 py-3.5 font-mono text-xs tracking-widest uppercase hover:border-primary hover:text-primary transition-colors active:scale-95"
          >
            <GitHubIcon className="w-4 h-4" />
            View on GitHub
          </a>
        </div>

        <p className="mt-6 text-xs text-on-surface-variant/70 font-mono uppercase tracking-widest">
          macOS 26+ · Apple Silicon
        </p>
      </div>
    </section>
  );
}

function AppPreview() {
  return (
    <section className="max-w-[var(--container-max)] mx-auto px-6 pb-24">
      <div className="relative">
        <div className="absolute -inset-8 bg-primary/15 blur-3xl rounded-full pointer-events-none" />
        <div className="relative bg-surface-container-low border border-primary/40 p-1.5 shadow-[0_0_80px_-12px_rgba(255,140,0,0.35)]">
          <Image
            src="/screenshot/screenshot1.png"
            alt="RxCode showing an active coding session with a diff and streaming response"
            width={3714}
            height={2228}
            priority
            sizes="(min-width: 1280px) 1240px, 100vw"
            className="block w-full h-auto"
          />
        </div>
      </div>
      <p className="mt-6 text-center font-mono text-[11px] tracking-widest uppercase text-on-surface-variant/70">
        Live session · diff review · streaming response
      </p>
    </section>
  );
}

function SupportedAgents() {
  return (
    <section
      id="agents"
      className="max-w-[var(--container-max)] mx-auto px-6 pb-24"
    >
      <div className="flex items-center gap-3 mb-8">
        <span className="font-mono text-[11px] tracking-widest uppercase text-primary">
          Supported Agents
        </span>
        <span className="flex-1 h-px bg-surface-variant" />
      </div>
      <p className="mb-8 max-w-3xl text-on-surface-variant leading-relaxed">
        Claude Code and Codex are built in, and RxCode also supports every
        client that speaks the Agent Client Protocol. Use the ACP registry to
        add clients such as Gemini CLI and OpenCode directly from Settings.
      </p>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
        <AgentCard
          name="Claude Code"
          tagline="Anthropic"
          description="Drive Claude Code sessions visually. Stream responses, approve tool calls with risk-based modals, and inspect every file the agent touches."
        />
        <AgentCard
          name="Codex"
          tagline="OpenAI"
          description="Run Codex inside the same interface. Switch between agents per project, with a unified session history, model picker, and permission flow."
        />
        <AgentCard
          name="ACP Clients"
          tagline="Protocol"
          description="Install and run ACP-compatible clients such as Gemini CLI, OpenCode, and registry agents. All ACP clients use the same chat, approval, and project workflow."
        />
      </div>
    </section>
  );
}

function AgentCard({
  name,
  tagline,
  description,
}: {
  name: string;
  tagline: string;
  description: string;
}) {
  return (
    <div className="group bg-surface border border-surface-variant p-7 hover:border-primary transition-colors">
      <div className="flex items-center justify-between mb-5">
        <h3 className="font-display text-2xl font-semibold tracking-tight">
          {name}
        </h3>
        <span className="font-mono text-[10px] tracking-widest uppercase text-on-surface-variant border border-surface-variant px-2 py-1">
          {tagline}
        </span>
      </div>
      <p className="text-on-surface-variant leading-relaxed">{description}</p>
      <div className="mt-6 flex items-center gap-2 text-primary font-mono text-[11px] tracking-widest uppercase">
        <DotIcon className="w-2 h-2" />
        Integrated &amp; live
      </div>
    </div>
  );
}

function FeatureBento() {
  return (
    <section
      id="features"
      className="max-w-[var(--container-max)] mx-auto px-6 pb-24"
    >
      <div className="flex items-center gap-3 mb-8">
        <span className="font-mono text-[11px] tracking-widest uppercase text-primary">
          Features
        </span>
        <span className="flex-1 h-px bg-surface-variant" />
      </div>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
        {FEATURE_CARDS.map((feature) => (
          <FeatureCard key={feature.title} feature={feature} />
        ))}
      </div>
    </section>
  );
}

function FeatureCard({
  feature,
}: {
  feature: (typeof FEATURE_CARDS)[number];
}) {
  return (
    <article
      className={`${feature.className} bg-surface border border-surface-variant p-7 flex flex-col hover:border-primary transition-colors`}
    >
      <div className="flex items-center gap-2 mb-4 font-mono text-[11px] tracking-widest uppercase text-primary">
        <SparkIcon className="w-3.5 h-3.5" />
        {feature.eyebrow}
      </div>
      <h3 className="font-display text-2xl md:text-3xl font-semibold mb-4 tracking-tight">
        {feature.title}
      </h3>
      <p className="text-on-surface-variant leading-relaxed">
        {feature.description}
      </p>
      <div className="mt-8 bg-surface-container border border-surface-variant relative overflow-hidden">
        <Image
          src={feature.image}
          alt={feature.alt}
          width={feature.width}
          height={feature.height}
          sizes={
            feature.className.includes("md:col-span-2")
              ? "(min-width: 768px) 760px, 100vw"
              : "(min-width: 768px) 380px, 100vw"
          }
          className="block w-full h-auto"
        />
      </div>
    </article>
  );
}

function CTA({
  release,
}: {
  release: Awaited<ReturnType<typeof getLatestRelease>>;
}) {
  return (
    <section className="bg-surface-container-lowest border-y border-surface-variant py-20">
      <div className="max-w-[var(--container-max)] mx-auto px-6 text-center">
        <h2 className="font-display text-4xl md:text-5xl font-semibold mb-4 tracking-tight">
          Ready to upgrade your AI coding experience?
        </h2>
        <p className="text-on-surface-variant mb-10 max-w-xl mx-auto leading-relaxed">
          Free, open source, and built for macOS. Download {release.tag} and
          start driving your agents visually.
        </p>
        <div className="flex flex-col sm:flex-row gap-3 justify-center">
          <a
            href={release.dmgUrl}
            className="inline-flex items-center justify-center gap-3 bg-primary text-on-primary px-8 py-3.5 font-mono text-xs tracking-widest uppercase border border-primary hover:bg-transparent hover:text-primary transition-colors active:scale-95"
          >
            <AppleIcon className="w-4 h-4" />
            Download RxCode {release.tag}
          </a>
          <Link
            href="/release"
            className="inline-flex items-center justify-center gap-2 border border-outline text-on-surface px-8 py-3.5 font-mono text-xs tracking-widest uppercase hover:border-primary hover:text-primary transition-colors active:scale-95"
          >
            Release notes
          </Link>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  const year = new Date().getFullYear();
  return (
    <footer className="w-full bg-surface border-t border-surface-variant">
      <div className="max-w-[var(--container-max)] mx-auto px-6 py-12 flex flex-col md:flex-row justify-between items-start md:items-center gap-6">
        <div className="flex flex-col gap-1">
          <span className="font-display text-2xl font-bold text-primary tracking-tight">
            RxCode
          </span>
          <span className="text-sm text-on-surface-variant/70">
            © {year} RxCode. All rights reserved.
          </span>
        </div>
        <nav className="flex flex-wrap gap-6 text-sm">
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            GitHub
          </a>
          <Link
            href="/release"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Release Notes
          </Link>
          <a
            href="#features"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Features
          </a>
          <a
            href="#agents"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Agents
          </a>
        </nav>
      </div>
    </footer>
  );
}

/* -------------------------- icons -------------------------- */

function AppleIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M16.365 1.43c0 1.14-.42 2.24-1.18 3.04-.78.82-2.06 1.46-3.1 1.38-.13-1.12.43-2.28 1.16-3.04.82-.86 2.22-1.5 3.12-1.38Zm3.95 16.94c-.55 1.26-1.18 2.46-2.07 3.5-1.04 1.22-2.07 2.04-3.34 2.04-1.22 0-1.57-.78-3.13-.78-1.6 0-1.98.76-3.18.8-1.28.04-2.42-1.04-3.45-2.26-2.16-2.56-3.82-7.24-1.6-10.4 1.1-1.56 3.05-2.54 5.13-2.58 1.4-.04 2.74.94 3.6.94.84 0 2.46-1.16 4.16-.98.72.04 2.66.3 3.92 2.22-.1.08-2.34 1.36-2.3 4.06.04 3.22 2.84 4.32 2.86 4.34-.02.08-.42 1.44-1.4 2.94Z" />
    </svg>
  );
}

function GitHubIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M12 .5C5.73.5.96 5.27.96 11.55c0 4.92 3.18 9.08 7.6 10.55.55.1.75-.24.75-.53v-1.86c-3.09.67-3.74-1.49-3.74-1.49-.5-1.27-1.23-1.6-1.23-1.6-1-.69.08-.67.08-.67 1.11.08 1.7 1.14 1.7 1.14.99 1.69 2.59 1.2 3.22.92.1-.72.39-1.2.7-1.48-2.46-.28-5.05-1.23-5.05-5.48 0-1.21.43-2.2 1.13-2.97-.11-.28-.49-1.4.11-2.91 0 0 .93-.3 3.05 1.13a10.57 10.57 0 0 1 5.56 0c2.12-1.44 3.05-1.13 3.05-1.13.6 1.51.22 2.63.11 2.91.7.77 1.13 1.76 1.13 2.97 0 4.26-2.6 5.2-5.07 5.48.4.34.76 1.01.76 2.04v3.02c0 .29.2.64.76.53 4.41-1.47 7.59-5.63 7.59-10.55C23.04 5.27 18.27.5 12 .5Z" />
    </svg>
  );
}

function SparkIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M12 2 14 9l7 2-7 2-2 7-2-7-7-2 7-2 2-7Z" />
    </svg>
  );
}

function DotIcon({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 8 8" className={className} aria-hidden="true">
      <circle cx="4" cy="4" r="4" fill="currentColor" />
    </svg>
  );
}
