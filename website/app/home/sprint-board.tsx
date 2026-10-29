"use client";

import Image from "next/image";
import { range, ScrollScene, useSceneProgress } from "./motion";
import { Eyebrow } from "./ui";

const COLUMNS = ["Backlog", "In progress", "Review", "Done"] as const;

const CARDS = [
  { title: "Passkey sign-in", tag: "Auth", agent: "/agents/claude.svg", start: 0.08 },
  { title: "Offline sync queue", tag: "Mobile", agent: "/agents/openai.svg", start: 0.16 },
  { title: "Billing webhooks", tag: "API", agent: "/agents/cursor.svg", start: 0.24 },
  { title: "Onboarding copy", tag: "Docs", agent: "/agents/gemini.svg", start: 0.3 },
  { title: "Dark mode tokens", tag: "UI", agent: "/agents/opencode.svg", start: 0.38 },
  { title: "Crash on resume", tag: "Bug", agent: "/agents/antigravity.svg", start: 0.46 },
];

const STEPS = [
  {
    title: "One board for the whole team",
    body: "Humans and agents share the same sprint. Stories, priorities, versions and milestones — synced across Mac, iPhone and Android.",
  },
  {
    title: "Cards move themselves",
    body: "Drop a card into In progress and an agent picks it up. Every run streams into its own thread, so you can step in at any time.",
  },
  {
    title: "Review, then ship",
    body: "Finished work lands in Review with a diff summary and a briefing. Approve it, and the card slides into Done.",
  },
];

export function SprintBoard() {
  return (
    <ScrollScene id="sprint" height="340vh">
      <SprintStage />
    </ScrollScene>
  );
}

function SprintStage() {
  const p = useSceneProgress();
  const stepIndex = p < 0.33 ? 0 : p < 0.66 ? 1 : 2;

  // Each card travels Backlog → Done over its own window of the scroll.
  const placed = CARDS.map((card) => {
    const travel = range(p, card.start, card.start + 0.42);
    return { ...card, column: Math.min(3, Math.floor(travel * 4)) };
  });
  const rows = new Map<number, number>();
  const positioned = placed.map((card) => {
    const row = rows.get(card.column) ?? 0;
    rows.set(card.column, row + 1);
    return { ...card, row };
  });

  return (
    <div className="mx-auto grid h-full max-w-[var(--container-max)] grid-cols-1 items-center gap-10 px-6 pb-10 pt-20 md:py-20 lg:grid-cols-[0.8fr_1.2fr] lg:gap-16">
      <div>
        <Eyebrow>Sprint board</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-6xl">
          Run a sprint with a team of agents.
        </h2>
        <div className="relative mt-6 h-36 md:mt-8 md:h-44">
          {STEPS.map((step, i) => (
            <div
              key={step.title}
              className="absolute inset-0 transition-all duration-700 ease-out"
              style={{
                opacity: i === stepIndex ? 1 : 0,
                transform: `translateY(${(i - stepIndex) * 24}px)`,
              }}
              aria-hidden={i !== stepIndex}
            >
              <h3 className="text-xl font-semibold text-on-surface">
                {step.title}
              </h3>
              <p className="mt-3 max-w-md text-base leading-relaxed md:text-lg text-on-surface-variant">
                {step.body}
              </p>
            </div>
          ))}
        </div>
        <div className="mt-4 flex gap-2">
          {STEPS.map((step, i) => (
            <span
              key={step.title}
              className={`h-1 rounded-full transition-all duration-500 ${
                i === stepIndex ? "w-10 bg-primary" : "w-4 bg-white/15"
              }`}
            />
          ))}
        </div>
      </div>

      <div className="glass-panel relative rounded-[28px] p-4 md:p-5">
        <div className="grid grid-cols-4 gap-2 md:gap-3">
          {COLUMNS.map((column, ci) => (
            <div key={column} className="flex items-center justify-between px-1 pb-3">
              <span className="truncate text-[11px] font-medium text-on-surface-variant md:text-xs">
                {column}
              </span>
              <span className="rounded-full bg-white/8 px-1.5 font-mono text-[10px] text-on-surface-variant">
                {positioned.filter((c) => c.column === ci).length}
              </span>
            </div>
          ))}
        </div>
        <div className="relative h-[330px] [--board-row:54px] md:h-[480px] md:[--board-row:76px]">
          <div className="absolute inset-0 grid grid-cols-4 gap-2 md:gap-3">
            {COLUMNS.map((column) => (
              <div key={column} className="rounded-2xl bg-white/[0.025]" />
            ))}
          </div>
          {positioned.map((card) => (
            <div
              key={card.title}
              className="absolute w-1/4 px-1 transition-[left,top] duration-700 ease-[cubic-bezier(0.22,1,0.36,1)] md:px-1.5"
              style={{ left: `${card.column * 25}%`, top: `calc(8px + ${card.row} * var(--board-row))` }}
            >
              <div
                className={`rounded-xl border p-2.5 shadow-lg transition-colors duration-500 md:p-3 ${
                  card.column === 3
                    ? "border-emerald-400/30 bg-emerald-400/[0.07]"
                    : card.column === 0
                      ? "border-white/10 bg-surface-container-high"
                      : "border-primary/40 bg-primary/[0.08]"
                }`}
              >
                <div className="flex items-center justify-between gap-1">
                  <span className="truncate text-[11px] font-medium text-on-surface md:text-[13px]">
                    {card.title}
                  </span>
                </div>
                <div className="mt-2 hidden items-center justify-between md:flex">
                  <span className="rounded-md bg-white/8 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-wider text-on-surface-variant">
                    {card.tag}
                  </span>
                  <span
                    className={`flex h-5 w-5 items-center justify-center rounded-full bg-black/40 ring-1 ring-white/10 transition-transform duration-500 ${
                      card.column === 1 ? "scale-110 ring-primary/70" : ""
                    }`}
                  >
                    <Image src={card.agent} alt="" width={12} height={12} unoptimized className="h-3 w-3" />
                  </span>
                </div>
                {card.column === 1 ? (
                  <div className="mt-2 h-0.5 overflow-hidden rounded-full bg-white/10">
                    <div className="progress-indeterminate h-full w-1/3 rounded-full bg-primary" />
                  </div>
                ) : null}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
