"use client";

import Image from "next/image";
import { range, ScrollScene, useSceneProgress } from "./motion";
import { CheckIcon, Eyebrow, SparkIcon } from "./ui";

const IDEA = "Build a habit tracker with cloud sync, widgets and a weekly review.";

const PLAN = [
  { title: "Data model & sync API", agent: "Codex", logo: "/agents/openai.svg", eta: "12 min" },
  { title: "SwiftUI habit screens", agent: "Claude Code", logo: "/agents/claude.svg", eta: "18 min" },
  { title: "Home-screen widgets", agent: "Cursor", logo: "/agents/cursor.svg", eta: "9 min" },
  { title: "Weekly review copy", agent: "Gemini CLI", logo: "/agents/gemini.svg", eta: "4 min" },
];

const HEADLINE =
  "Plan your next big idea. Your agent team breaks it down, picks the most efficient agent for each piece, and finishes it fast and clean.";

export function AgentTeam() {
  return (
    <ScrollScene id="team" height="320vh">
      <TeamStage />
    </ScrollScene>
  );
}

function TeamStage() {
  const p = useSceneProgress();
  const typed = Math.round(range(p, 0.05, 0.3) * IDEA.length);
  const words = HEADLINE.split(" ");
  const lit = range(p, 0, 0.75) * words.length;

  return (
    <div className="mx-auto grid h-full max-w-[var(--container-max)] grid-cols-1 items-center gap-10 px-6 pb-10 pt-20 lg:grid-cols-2 lg:gap-16">
      <div>
        <Eyebrow>Agent team</Eyebrow>
        <p className="mt-6 font-display text-2xl font-semibold leading-[1.2] tracking-[-0.02em] md:text-[44px]">
          {words.map((word, i) => (
            <span
              key={`${word}-${i}`}
              className="transition-colors duration-300"
              style={{
                color:
                  i < lit
                    ? i < 5
                      ? "#4df5c7"
                      : "#e8f4ff"
                    : "rgba(229,226,225,0.18)",
              }}
            >
              {word}{" "}
            </span>
          ))}
        </p>
      </div>

      <div className="glass-panel rounded-[28px] p-5 md:p-6">
        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="mb-2 flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.2em] text-on-surface-variant/70">
            <SparkIcon className="h-3.5 w-3.5 text-primary" />
            New idea
          </div>
          <p className="min-h-[3.2em] text-base text-on-surface md:text-lg">
            {IDEA.slice(0, typed)}
            <span className="caret ml-0.5 inline-block h-5 w-[2px] translate-y-1 bg-primary" />
          </p>
        </div>

        <div className="mt-4 flex items-center gap-3 px-1 text-xs text-on-surface-variant">
          <span className="h-px flex-1 bg-white/10" />
          <span
            className="font-mono uppercase tracking-[0.2em] transition-opacity duration-500"
            style={{ opacity: p > 0.3 ? 1 : 0.25 }}
          >
            Plan · 4 tasks
          </span>
          <span className="h-px flex-1 bg-white/10" />
        </div>

        <ul className="mt-4 flex flex-col gap-2.5">
          {PLAN.map((item, i) => {
            const shown = range(p, 0.3 + i * 0.06, 0.38 + i * 0.06);
            const assigned = p > 0.6 + i * 0.06;
            const done = p > 0.8 + i * 0.04;
            return (
              <li
                key={item.title}
                className="flex items-center gap-3 rounded-2xl border border-white/8 bg-white/[0.03] p-3 transition-[border-color] duration-500"
                style={{
                  opacity: shown,
                  transform: `translateY(${(1 - shown) * 16}px)`,
                  borderColor: done ? "rgba(52,211,153,0.35)" : undefined,
                }}
              >
                <span
                  className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full border transition-all duration-500 ${
                    done
                      ? "border-emerald-400 bg-emerald-400 text-black"
                      : "border-white/20 text-transparent"
                  }`}
                >
                  <CheckIcon className="h-3.5 w-3.5" />
                </span>
                <span className="flex-1 truncate text-sm text-on-surface">
                  {item.title}
                </span>
                <span
                  className="flex items-center gap-2 rounded-full border border-white/10 bg-black/40 py-1 pl-1 pr-2.5 transition-all duration-500"
                  style={{
                    opacity: assigned ? 1 : 0,
                    transform: assigned ? "scale(1)" : "scale(0.8)",
                  }}
                >
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-white/10">
                    <Image src={item.logo} alt="" width={12} height={12} unoptimized className="h-3 w-3" />
                  </span>
                  <span className="text-xs text-on-surface">{item.agent}</span>
                  <span className="hidden font-mono text-[10px] text-on-surface-variant/70 sm:inline">
                    {item.eta}
                  </span>
                </span>
              </li>
            );
          })}
        </ul>

        <div
          className="mt-4 flex items-center justify-between rounded-2xl bg-primary/10 px-4 py-3 text-sm transition-opacity duration-500"
          style={{ opacity: p > 0.9 ? 1 : 0 }}
        >
          <span className="text-on-surface">Shipped in parallel</span>
          <span className="font-mono text-xs text-primary">4 agents · 18 min</span>
        </div>
      </div>
    </div>
  );
}
