"use client";

import Image from "next/image";
import type { CSSProperties } from "react";
import {
  easeOut,
  range,
  ScrollScene,
  useLeaveProgress,
  useSceneProgress,
} from "./motion";
import {
  AGENTS,
  ArrowRightIcon,
  BoltIcon,
  CloudIcon,
  Eyebrow,
  FLOWCY_URL,
  LockIcon,
  SparkIcon,
} from "./ui";

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
const ORBIT_AGENTS = AGENTS.slice(0, 4);

export function FlowcyCloud() {
  return (
    <ScrollScene id="flowcy" height="360vh" className="z-10" clip={false}>
      <FlowcyStage />
    </ScrollScene>
  );
}

function FlowcyStage() {
  const p = useSceneProgress();
  const leave = useLeaveProgress("flowcy");
  // The cloud forms, teammates spiral out onto the outer ring, then agents
  // join the inner ring while each feature card lands in turn. At the end the
  // orbits spin up, and as the section scrolls away the whole system tumbles
  // and falls into the next section.
  const core = easeOut(range(p, 0, 0.18));
  const step = Math.min(3, Math.floor(range(p, 0.1, 0.78) * 4));
  const cta = range(p, 0.66, 0.76);
  const exit = range(p, 0.78, 1);
  const spin = exit * exit * 120 + leave * 200;

  return (
    <div className="mx-auto grid h-full max-w-[var(--container-max)] grid-cols-1 items-center gap-12 px-6 pb-10 pt-24 lg:grid-cols-2 lg:gap-16">
      <div style={{ opacity: 1 - exit, transform: `translateY(${-exit * 40}px)` }}>
        <Eyebrow>Flowcy Cloud</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          Your team&apos;s
          <br />
          <span className="text-gradient-primary">cloud workspace.</span>
        </h2>
        <p className="mt-4 max-w-xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          Flowcy brings your boards, agents and people together. Invite
          your team, assign work to humans or agents, and let every
          device pick up where the last one left off.
        </p>
        <div className="mt-8 grid grid-cols-1 gap-3 sm:grid-cols-2">
          {FLOWCY_FEATURES.map((feature, i) => {
            const shown = easeOut(range(p, 0.1 + i * 0.18, 0.22 + i * 0.18));
            const current = i === step && shown > 0;
            return (
              <div
                key={feature.title}
                className={`glass-panel rounded-2xl p-4 transition-[border-color,background-color] duration-500 md:p-5 ${
                  current ? "border-primary/50 bg-primary/[0.06]" : ""
                }`}
                style={{
                  opacity: 0.15 + shown * 0.85,
                  transform: `translateY(${(1 - shown) * 24}px)`,
                }}
              >
                <span className="text-primary">{feature.icon}</span>
                <h3 className="mt-3 font-semibold text-on-surface">{feature.title}</h3>
                <p className="mt-1.5 text-sm leading-relaxed text-on-surface-variant">
                  {feature.body}
                </p>
              </div>
            );
          })}
        </div>
        <div
          className="mt-6"
          style={{ opacity: cta, transform: `translateY(${(1 - cta) * 12}px)` }}
        >
          <a href={FLOWCY_URL} target="_blank" rel="noreferrer" className="btn-secondary">
            Explore Flowcy
            <ArrowRightIcon className="h-4 w-4" />
          </a>
        </div>
      </div>

      <div
        className="relative mx-auto hidden aspect-square w-full max-w-[min(520px,68vh)] will-change-transform [container-type:inline-size] lg:block"
        style={{
          // Outpaces the scroll so the system holds, then falls with gravity.
          transform: `translateY(${leave * (1 + leave * 0.9) * 100}vh) rotate(${leave * 35}deg) scale(${1 + leave * 0.2})`,
          opacity: 1 - range(leave, 0.55, 1),
        }}
      >
        <div
          className="absolute inset-0"
          style={{ opacity: core, transform: `scale(${0.6 + core * 0.4})` }}
        >
          <div className="absolute inset-0 rounded-full border border-white/5" />
          <div className="absolute inset-[14%] rounded-full border border-white/8" />
          <div className="absolute inset-[30%] rounded-full border border-primary/20" />
        </div>
        <div
          className="absolute inset-[38%] z-10 flex items-center justify-center rounded-full bg-gradient-to-br from-primary to-[#00cfbb]"
          style={{
            transform: `scale(${0.4 + core * 0.6})`,
            boxShadow: `0 0 ${80 + step * 20}px ${10 + step * 5}px rgba(0,207,187,${0.2 + core * 0.15})`,
          }}
        >
          <CloudIcon className="h-1/2 w-1/2 text-white" />
        </div>

        <div className="orbit absolute inset-0">
          {TEAM.map((initials, i) => {
            const out = easeOut(range(p, 0.12 + i * 0.05, 0.3 + i * 0.05));
            return (
              <span
                key={initials}
                className="orbit-item absolute left-1/2 top-1/2 flex h-12 w-12 items-center justify-center rounded-full border border-white/15 bg-surface-container-high text-sm font-semibold text-on-surface shadow-xl"
                style={{ "--angle": `${(360 / TEAM.length) * i + spin}deg`, "--radius": `${43 * out}cqw` } as CSSProperties}
              >
                <span className="orbit-counter">{initials}</span>
              </span>
            );
          })}
        </div>
        <div className="orbit orbit-slow absolute inset-[14%]">
          {ORBIT_AGENTS.map((agent, i) => {
            const out = easeOut(range(p, 0.4 + i * 0.06, 0.56 + i * 0.06));
            return (
              <span
                key={agent.name}
                className="orbit-item absolute left-1/2 top-1/2 flex h-10 w-10 items-center justify-center rounded-2xl border border-white/10 bg-black/70 backdrop-blur"
                style={{ "--angle": `${90 * i + 45 - spin * 1.4}deg`, "--radius": `${29 * out}cqw` } as CSSProperties}
              >
                <Image src={agent.logo} alt="" width={20} height={20} unoptimized className="orbit-counter h-5 w-5" />
              </span>
            );
          })}
        </div>
      </div>
    </div>
  );
}

