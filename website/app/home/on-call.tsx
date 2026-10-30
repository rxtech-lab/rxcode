"use client";

import Image from "next/image";
import {
  easeOut,
  range,
  ScrollScene,
  useLeaveProgress,
  useSceneProgress,
} from "./motion";
import { CheckIcon, Eyebrow } from "./ui";

// Hours are on a continuous clock that runs past midnight (25 = 01:00).
const START = 22;
const END = 32;

const EVENTS = [
  {
    at: 23.67,
    alert: "Nightly build failed",
    fix: "Patched a flaky test · PR #482",
    agent: "Codex",
    logo: "/agents/openai.svg",
  },
  {
    at: 25.25,
    alert: "New issue: crash on launch",
    fix: "Reproduced, labeled P1, fix drafted",
    agent: "Claude Code",
    logo: "/agents/claude.svg",
  },
  {
    at: 27.5,
    alert: "6 dependency updates",
    fix: "5 merged after tests, 1 flagged",
    agent: "Gemini CLI",
    logo: "/agents/gemini.svg",
  },
  {
    at: 29,
    alert: "Scheduled: release notes",
    fix: "Draft ready for your review",
    agent: "Claude Code",
    logo: "/agents/claude.svg",
  },
  {
    at: 31.75,
    alert: "Morning briefing",
    fix: "Sent to your phone",
    agent: "RxCode",
    logo: null,
  },
];

const formatHour = (h: number) => {
  const hours = Math.floor(h) % 24;
  const minutes = Math.floor((h % 1) * 60);
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
};

/** Point on the 24-hour dial (midnight at the top) at `radius`. */
const dialPoint = (h: number, radius: number) => {
  const angle = ((h % 24) / 24) * Math.PI * 2 - Math.PI / 2;
  // Rounded so server and client render identical SVG attributes.
  const round = (v: number) => Math.round(v * 1000) / 1000;
  return { x: round(50 + Math.cos(angle) * radius), y: round(50 + Math.sin(angle) * radius) };
};

const arcPath = (from: number, to: number, radius: number) => {
  const a = dialPoint(from, radius);
  const b = dialPoint(to, radius);
  const large = to - from > 12 ? 1 : 0;
  return `M${a.x},${a.y} A${radius},${radius} 0 ${large} 1 ${b.x},${b.y}`;
};

export function OnCall() {
  return (
    <ScrollScene id="oncall" height="340vh" clip={false}>
      <OnCallStage />
    </ScrollScene>
  );
}

function OnCallStage() {
  const p = useSceneProgress();
  const leave = useLeaveProgress("oncall");
  // The night runs from 22:00 to 08:00 as you scroll; every alert the clock
  // hand passes is picked up and resolved by an agent.
  const now = START + range(p, 0.04, 0.9) * (END - START);
  const intro = easeOut(range(p, 0, 0.12));
  const handled = EVENTS.filter((event) => now >= event.at + 0.4).length;
  const hand = dialPoint(now, 34);

  return (
    <div
      className="mx-auto grid h-full max-w-[var(--container-max)] grid-cols-1 items-center gap-10 px-6 pb-10 pt-24 lg:grid-cols-[1fr_1.1fr] lg:gap-16"
      style={{
        transform: `translateY(${leave * 100}vh) scale(${1 - leave * 0.14})`,
        opacity: 1 - leave * 0.8,
        filter: leave > 0 ? `blur(${leave * 8}px)` : undefined,
      }}
    >
      <div>
        <Eyebrow>24H on call</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          Agents on your side.
          <br />
          <span className="text-gradient-primary">On call 24 hours.</span>
        </h2>
        <p className="mt-4 max-w-xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          While you sleep, your agents watch CI, triage new issues, review
          dependency updates and keep schedules running. When you wake up,
          the fixes and a briefing are waiting.
        </p>

        <div
          className="relative mx-auto mt-10 aspect-square w-full max-w-[280px] lg:mx-0"
          style={{ opacity: intro, transform: `scale(${0.85 + intro * 0.15})` }}
        >
          <svg viewBox="0 0 100 100" className="absolute inset-0 h-full w-full">
            <circle cx="50" cy="50" r="44" fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth="0.6" />
            {Array.from({ length: 24 }, (_, h) => {
              const a = dialPoint(h, 44);
              const b = dialPoint(h, h % 6 === 0 ? 39 : 41.5);
              return (
                <line
                  key={h}
                  x1={a.x}
                  y1={a.y}
                  x2={b.x}
                  y2={b.y}
                  stroke="rgba(255,255,255,0.25)"
                  strokeWidth={h % 6 === 0 ? 0.9 : 0.5}
                />
              );
            })}
            {now > START + 0.05 && (
              <path
                d={arcPath(START, now, 44)}
                fill="none"
                stroke="#4df5c7"
                strokeWidth="1.6"
                strokeLinecap="round"
              />
            )}
            {EVENTS.map((event) => {
              const point = dialPoint(event.at, 44);
              const reached = now >= event.at;
              return (
                <circle
                  key={event.at}
                  cx={point.x}
                  cy={point.y}
                  r={reached ? 2.2 : 1.6}
                  fill={reached ? "#34d399" : "#1c385c"}
                  stroke={reached ? "#041438" : "rgba(255,255,255,0.3)"}
                  strokeWidth="0.6"
                />
              );
            })}
            <line x1="50" y1="50" x2={hand.x} y2={hand.y} stroke="#e8f4ff" strokeWidth="1.2" strokeLinecap="round" />
            <circle cx="50" cy="50" r="2" fill="#4df5c7" />
          </svg>
          <div className="absolute inset-0 flex flex-col items-center justify-center pt-16">
            <span className="font-mono text-2xl text-on-surface">{formatHour(now)}</span>
            <span className="mt-1 font-mono text-[10px] uppercase tracking-[0.2em] text-on-surface-variant/70">
              {now < 30 ? "You're asleep" : "Good morning"}
            </span>
          </div>
        </div>
      </div>

      <div className="glass-panel hidden rounded-[28px] p-5 md:p-6 lg:block">
        <div className="flex items-center justify-between">
          <span className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.2em] text-on-surface-variant/70">
            <span className="relative flex h-2 w-2">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60" />
              <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-400" />
            </span>
            On call tonight
          </span>
          <span className="font-mono text-xs text-on-surface-variant">
            <span className="text-primary">{handled}</span> handled · 0 pages
          </span>
        </div>

        <ol className="mt-5 flex flex-col gap-3">
          {EVENTS.map((event) => {
            const shown = easeOut(range(now, event.at - 0.6, event.at));
            const resolved = now >= event.at + 0.4;
            return (
              <li
                key={event.at}
                className="rounded-2xl border border-white/8 bg-white/[0.03] p-3.5 transition-[border-color] duration-500"
                style={{
                  opacity: 0.12 + shown * 0.88,
                  transform: `translateX(${(1 - shown) * 16}px)`,
                  borderColor: resolved ? "rgba(52,211,153,0.35)" : undefined,
                }}
              >
                <div className="flex items-center gap-3">
                  <span className="w-11 shrink-0 font-mono text-xs text-on-surface-variant">
                    {formatHour(event.at)}
                  </span>
                  <span
                    className={`h-1.5 w-1.5 shrink-0 rounded-full transition-colors duration-500 ${
                      resolved ? "bg-emerald-400" : "bg-amber-400"
                    }`}
                  />
                  <span className="flex-1 truncate text-sm text-on-surface">{event.alert}</span>
                </div>
                <div
                  className="ml-14 mt-2 flex items-center gap-2 text-xs text-on-surface-variant transition-opacity duration-500"
                  style={{ opacity: resolved ? 1 : 0 }}
                >
                  <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-white/10">
                    {event.logo === null ? (
                      <CheckIcon className="h-3 w-3 text-primary" />
                    ) : (
                      <Image src={event.logo} alt="" width={12} height={12} unoptimized className="h-3 w-3" />
                    )}
                  </span>
                  <span className="text-on-surface">{event.agent}</span>
                  <span className="truncate">· {event.fix}</span>
                </div>
              </li>
            );
          })}
        </ol>
      </div>
    </div>
  );
}
